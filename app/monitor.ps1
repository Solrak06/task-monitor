# Claude Task Monitor: CPU y RAM por sesión de Claude Code, con estados, pausa, estilos y ajustes.
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeTaskMonitor', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.IO;
using System.Globalization;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;

namespace TaskMon {
  // A bag of values a card binds to as [Key]; a set raises a change only when the value differs.
  // Between Begin() and End() the changes fold into one, so the card's bindings update once per refresh.
  public class Card : INotifyPropertyChanged {
    private readonly Dictionary<string, object> values = new Dictionary<string, object>();
    private bool batching, dirty;
    public event PropertyChangedEventHandler PropertyChanged;
    public object this[string key] {
      get { object v; return values.TryGetValue(key, out v) ? v : null; }
      set {
        object old;
        if (values.TryGetValue(key, out old) && Equals(old, value)) return;
        values[key] = value;
        if (batching) dirty = true; else Raise();
      }
    }
    public void Begin() { batching = true; }
    public void End() { batching = false; if (dirty) { dirty = false; Raise(); } }
    void Raise() { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs("Item[]")); }
  }

  public class Proc {
    public int Pid; public int Ppid; public string Name; public long WorkingSet; public long CpuTime; public DateTime Created;
  }

  // The snapshot indexed by pid and by parent, built in C# (a PowerShell loop over 500 processes costs ~50 ms).
  public class Tree {
    public Dictionary<int, Proc> ById = new Dictionary<int, Proc>();
    public Dictionary<int, List<int>> Children = new Dictionary<int, List<int>>();
    public List<Proc> Claude = new List<Proc>();
    public Tree(List<Proc> procs) {
      foreach (var p in procs) {
        ById[p.Pid] = p;
        List<int> c;
        if (!Children.TryGetValue(p.Ppid, out c)) { c = new List<int>(); Children[p.Ppid] = c; }
        c.Add(p.Pid);
        if (string.Equals(p.Name, "claude.exe", StringComparison.OrdinalIgnoreCase)) Claude.Add(p);
      }
    }
  }

  // A tiny pixel canvas for the pixel-art view: drawn once per (state, frame), kept as a frozen bitmap.
  public class Pix {
    public readonly int W, H;
    readonly uint[] px;
    public Pix(int w, int h) { W = w; H = h; px = new uint[w * h]; }
    static uint Parse(string hex) {
      string s = hex.TrimStart('#');
      uint v = Convert.ToUInt32(s, 16);
      return s.Length <= 6 ? 0xFF000000 | v : v;
    }
    public void Rect(int x, int y, int w, int h, string color) {
      uint c = Parse(color);
      for (int j = y; j < y + h; j++) for (int i = x; i < x + w; i++) Put(i, j, c);
    }
    public void Dot(int x, int y, string color) { Put(x, y, Parse(color)); }
    // Rows of '#' separated by '/', e.g. ".#./###"
    public void Glyph(int x, int y, string rows, string color) {
      uint c = Parse(color);
      string[] r = rows.Split('/');
      for (int j = 0; j < r.Length; j++) for (int i = 0; i < r[j].Length; i++) if (r[j][i] == '#') Put(x + i, y + j, c);
    }
    // Degradado vertical, de arriba abajo
    public void Gradient(int x, int y, int w, int h, string top, string bottom) {
      uint a = Parse(top), b = Parse(bottom);
      for (int j = 0; j < h; j++) {
        uint c = Lerp(a, b, h <= 1 ? 0 : (double)j / (h - 1));
        for (int i = 0; i < w; i++) Put(x + i, y + j, c);
      }
    }
    static uint Lerp(uint a, uint b, double t) {
      uint o = 0;
      for (int s = 0; s <= 24; s += 8) { double ca = (a >> s) & 255, cb = (b >> s) & 255; o |= (uint)Math.Round(ca + (cb - ca) * t) << s; }
      return o;
    }
    // Motas sueltas para dar textura (siempre las mismas para la misma semilla)
    public void Noise(int x, int y, int w, int h, string color, double density, int seed) {
      var r = new Random(seed); uint c = Parse(color);
      for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) if (r.NextDouble() < density) Put(x + i, y + j, c);
    }
    public void Circle(int cx, int cy, int rad, string color) {
      uint c = Parse(color);
      for (int j = -rad; j <= rad; j++) for (int i = -rad; i <= rad; i++) if (i * i + j * j <= rad * rad + rad / 2) Put(cx + i, cy + j, c);
    }
    // Halo de luz que se apaga hacia fuera
    public void Glow(int cx, int cy, int rad, string color) {
      uint c = Parse(color); double a0 = c >> 24;
      for (int j = -rad; j <= rad; j++) for (int i = -rad; i <= rad; i++) {
        double d = Math.Sqrt(i * i + j * j) / rad; if (d > 1) continue;
        uint a = (uint)Math.Round(a0 * (1 - d) * (1 - d)); if (a == 0) continue;
        Put(cx + i, cy + j, (a << 24) | (c & 0xFFFFFF));
      }
    }
    public void Line(int x0, int y0, int x1, int y1, string color) {
      uint c = Parse(color);
      int dx = Math.Abs(x1 - x0), dy = -Math.Abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy;
      while (true) {
        Put(x0, y0, c);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
      }
    }
    // Degradado tramado (Bayer 4x4) entre varios colores "a,b,c...": el degradado clásico del pixel art
    static readonly int[,] bayer = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } };
    public void Dither(int x, int y, int w, int h, string csv) {
      var parts = csv.Split(','); var c = new uint[parts.Length];
      for (int k = 0; k < parts.Length; k++) c[k] = Parse(parts[k].Trim());
      int n = c.Length;
      for (int j = 0; j < h; j++) {
        double t = (h <= 1 ? 0 : (double)j / (h - 1)) * (n - 1); int band = Math.Min(n - 1, (int)t); double fr = t - band;
        for (int i = 0; i < w; i++) {
          double thr = (bayer[(y + j) & 3, (x + i) & 3] + 0.5) / 16.0;
          Put(x + i, y + j, fr > thr && band + 1 < n ? c[band + 1] : c[band]);
        }
      }
    }
    // Tramado de un color con cobertura 0..1 (sombras y luces suaves sin transparencias)
    public void DitherFill(int x, int y, int w, int h, string color, double cover) {
      uint c = Parse(color);
      for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) if ((bayer[(y + j) & 3, (x + i) & 3] + 0.5) / 16.0 < cover) Put(x + i, y + j, c);
    }
    // Banda que se va apagando hacia abajo (oclusión bajo la pared, sombras largas)
    public void DitherFade(int x, int y, int w, int h, string color, double from, double to) {
      for (int j = 0; j < h; j++) DitherFill(x, y + j, w, 1, color, from + (to - from) * (h <= 1 ? 0 : (double)j / (h - 1)));
    }
    public void Ellipse(int cx, int cy, int rx, int ry, string color) {
      uint c = Parse(color);
      for (int j = -ry; j <= ry; j++) for (int i = -rx; i <= rx; i++) if ((double)i * i / (rx * rx + 0.01) + (double)j * j / (ry * ry + 0.01) <= 1.0) Put(cx + i, cy + j, c);
    }
    // Bisel: luz arriba e izquierda, sombra abajo y derecha
    public void Bevel(int x, int y, int w, int h, string hi, string lo) {
      uint a = Parse(hi), b = Parse(lo);
      for (int i = 0; i < w; i++) { Put(x + i, y, a); Put(x + i, y + h - 1, b); }
      for (int j = 1; j < h - 1; j++) { Put(x, y + j, a); Put(x + w - 1, y + j, b); }
    }
    // Pega encima otra capa del mismo tamaño
    public void Blit(Pix o) { for (int k = 0; k < px.Length && k < o.px.Length; k++) if (o.px[k] != 0) Put(k % W, k / W, o.px[k]); }
    // Contorno oscuro alrededor de lo opaco: los personajes se leen bien sobre fondos cargados
    public void Outline(string color) {
      uint c = Parse(color);
      var solid = new bool[W * H];
      for (int k = 0; k < px.Length; k++) solid[k] = (px[k] >> 24) >= 200;
      var add = new List<int>();
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        int k = y * W + x; if (solid[k]) continue;
        if ((x > 0 && solid[k - 1]) || (x < W - 1 && solid[k + 1]) || (y > 0 && solid[k - W]) || (y < H - 1 && solid[k + W])) add.Add(k);
      }
      foreach (int k in add) px[k] = c;
    }
    void Put(int x, int y, uint c) {
      if (x < 0 || y < 0 || x >= W || y >= H) return;
      uint a = c >> 24;
      if (a == 0) return;
      int k = y * W + x;
      if (a == 255) { px[k] = c; return; }
      uint d = px[k];
      double sa = a / 255.0, da = (d >> 24) / 255.0, oa = sa + da * (1 - sa);
      uint outc = (uint)Math.Round(oa * 255) << 24;
      for (int s = 0; s <= 16; s += 8) {
        double sc = (c >> s) & 255, dc = (d >> s) & 255;
        outc |= (uint)Math.Round((sc * sa + dc * da * (1 - sa)) / oa) << s;
      }
      px[k] = outc;
    }
    public BitmapSource ToBitmap() {
      var b = BitmapSource.Create(W, H, 96, 96, PixelFormats.Bgra32, null, px, W * 4);
      b.Freeze();
      return b;
    }
  }

  // Anima los Claudes de las tarjetas: cada uno con sus fotogramas y su desfase, en un solo temporizador.
  // Desde PowerShell solo se toca cuando cambia una escena; cada vuelta es un cambio de Source por tarjeta.
  public class Animator {
    class Entry { public DependencyObject Target; public BitmapSource[] Frames; public int Offset; public bool Slow; }
    readonly Dictionary<int, Entry> entries = new Dictionary<int, Entry>();
    readonly DependencyProperty prop;
    readonly System.Windows.Threading.DispatcherTimer timer = new System.Windows.Threading.DispatcherTimer();
    int tick;
    public Animator(DependencyProperty sourceProperty, int intervalMs) {
      prop = sourceProperty;
      timer.Interval = TimeSpan.FromMilliseconds(intervalMs);
      timer.Tick += (s, e) => { tick++; foreach (var en in entries.Values) Apply(en); };
    }
    // Devuelve false si ya estaba igual (misma tarjeta y mismos fotogramas)
    public bool Set(int key, DependencyObject target, BitmapSource[] frames, bool slow) {
      Entry en;
      if (entries.TryGetValue(key, out en) && ReferenceEquals(en.Target, target) && ReferenceEquals(en.Frames, frames)) return false;
      en = new Entry { Target = target, Frames = frames, Offset = Math.Abs(key), Slow = slow };
      entries[key] = en;
      Apply(en);
      return true;
    }
    public void Remove(int key) { entries.Remove(key); }
    public void Start() { if (!timer.IsEnabled) timer.Start(); }
    public void Stop() { timer.Stop(); }
    void Apply(Entry en) {
      int t = en.Slow ? tick >> 1 : tick;
      var src = en.Frames[(t + en.Offset) % en.Frames.Length];
      if (!ReferenceEquals(en.Target.GetValue(prop), src)) en.Target.SetValue(prop, src);
    }
  }

  // Escenario: cada Claude anda por el mapa hasta su sitio y hace allí su actividad; se puede arrastrar con el ratón.
  // Desde PowerShell solo se le dice adónde ir y con qué fotogramas; el movimiento y la animación van aquí.
  public class StageActor {
    public int Key; public System.Windows.Controls.Image Img, Emo; public FrameworkElement Tag; public ScaleTransform Flip;
    public double X, Y, TX, TY, Speed = 12, T; public bool Walking, Left, Slow; public int Offset;
    public BitmapSource[] Walk, Act, Blink, Drag, EmoFrames; public BitmapSource[][] Moods;
    public double EmoLeft, EmoT, NextEmo = 4, BlinkLeft, NextBlink = 3, FootD; public bool Leaving, FootL;
    public System.Windows.Controls.Image Mark; public BitmapSource MarkFrame;
    public int Team = -1; public bool Moving; public double KickCd, CeleLeft, LandLeft;
    public BitmapSource[] Run, Ready, Cele, Land;
  }
  // Cosas vivas del decorado: nubes, gaviotas, el gato, el robot aspirador... Siguen su ruta (x, y, pausa) sin parar
  public class StageProp {
    public System.Windows.Controls.Image Img; public ScaleTransform Flip; public BitmapSource[] Frames;
    public double X, Y, AX, AY, Period = 0.3, T, Speed, Wait; public int Z = -1, Idx; public bool Wrap, CanFlip, Left;
    public List<double[]> Path;
    public BitmapSource[] Near; public double Radius; public bool StopNear, IsNear;
    public BitmapSource[] Startle; public double StartleRadius;
  }
  public class Stage {
    readonly System.Windows.Controls.Canvas canvas;
    readonly Dictionary<int, StageActor> actors = new Dictionary<int, StageActor>();
    readonly Dictionary<string, StageProp> props = new Dictionary<string, StageProp>();
    readonly Dictionary<long, DateTime> greeted = new Dictionary<long, DateTime>();
    readonly System.Windows.Threading.DispatcherTimer timer = new System.Windows.Threading.DispatcherTimer();
    static readonly Random rnd = new Random();
    DateTime last = DateTime.Now;
    StageActor pressed; Point pressPt; bool dragging; double grabX, grabY;
    public double MinX, MinY, MaxX = 1000, MaxY = 1000;
    public Action<int, double, double> OnDrop;
    // Emociones comunes: saludo al cruzarse, susto al cogerlos y mareo al soltarlos
    public BitmapSource[] GreetFrames, ScaredFrames, DizzyFrames;
    public Stage(System.Windows.Controls.Canvas c) {
      canvas = c;
      timer.Interval = TimeSpan.FromMilliseconds(70);
      timer.Tick += (s, e) => Step();
    }
    public void Start() { if (!timer.IsEnabled) { last = DateTime.Now; timer.Start(); } }
    public void Stop() { timer.Stop(); }
    public bool Has(int k) { return actors.ContainsKey(k); }
    public double GetX(int k) { StageActor a; return actors.TryGetValue(k, out a) ? a.X : 0; }
    public double GetY(int k) { StageActor a; return actors.TryGetValue(k, out a) ? a.Y : 0; }
    public bool IsWalking(int k) { StageActor a; return actors.TryGetValue(k, out a) && a.Walking; }
    public System.Windows.Controls.Image GetImage(int k) { StageActor a; return actors.TryGetValue(k, out a) ? a.Img : null; }
    public int[] Keys() { return new List<int>(actors.Keys).ToArray(); }
    public void Add(int key, object data, FrameworkElement tag, BitmapSource[] walk, BitmapSource[] drag, double x, double y) {
      Remove(key);
      var a = new StageActor { Key = key, Tag = tag, Walk = walk, Drag = drag, Act = walk, X = x, Y = y, TX = x, TY = y, Offset = Math.Abs(key) % 7 };
      a.NextEmo = 2 + rnd.NextDouble() * 6; a.NextBlink = 1 + rnd.NextDouble() * 4;
      a.Img = new System.Windows.Controls.Image { Width = 32, Height = 28, Stretch = Stretch.Fill, DataContext = data, Cursor = System.Windows.Input.Cursors.Hand };
      a.Flip = new ScaleTransform(1, 1, 16, 0); a.Img.RenderTransform = a.Flip;
      a.Img.MouseDown += Down; a.Img.MouseMove += Move; a.Img.MouseUp += Up;
      a.Emo = new System.Windows.Controls.Image { Width = 14, Height = 13, Stretch = Stretch.Fill, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
      System.Windows.Controls.Panel.SetZIndex(a.Emo, 950000);
      a.Mark = new System.Windows.Controls.Image { Width = 16, Height = 6, Stretch = Stretch.Fill, IsHitTestVisible = false };
      canvas.Children.Add(a.Mark); canvas.Children.Add(a.Img); canvas.Children.Add(a.Emo);
      if (tag != null) { canvas.Children.Add(tag); System.Windows.Controls.Panel.SetZIndex(tag, 1000000); }
      actors[key] = a;
      Draw(a);
    }
    // Andar hasta x,y y, al llegar, hacer la actividad
    public void Go(int key, double x, double y, BitmapSource[] act, bool slow, double speed) {
      StageActor a; if (!actors.TryGetValue(key, out a)) return;
      a.TX = x; a.TY = y; a.Act = act; a.Slow = slow; a.Speed = speed;
      if (!(dragging && a == pressed)) a.Walking = Math.Abs(a.X - x) > 0.5 || Math.Abs(a.Y - y) > 0.5;
      Draw(a);
    }
    // Aparecer ya en su sitio
    public void Put(int key, double x, double y, BitmapSource[] act, bool slow) {
      StageActor a; if (!actors.TryGetValue(key, out a)) return;
      a.X = a.TX = x; a.Y = a.TY = y; a.Act = act; a.Slow = slow; a.Walking = false;
      Draw(a);
    }
    // Aro de su color bajo los pies; en el partido, el de su equipo
    public BitmapSource[] TeamMarks;
    public void SetMark(int key, BitmapSource mark) { StageActor a; if (actors.TryGetValue(key, out a)) { a.MarkFrame = mark; Draw(a); } }
    public void SetLand(int key, BitmapSource[] land) { StageActor a; if (actors.TryGetValue(key, out a)) a.Land = land; }
    public void SetPlay(int key, BitmapSource[] run, BitmapSource[] ready, BitmapSource[] cele) { StageActor a; if (actors.TryGetValue(key, out a)) { a.Run = run; a.Ready = ready; a.Cele = cele; } }
    public bool InMatch(int key) { StageActor a; return actors.TryGetValue(key, out a) && a.Team >= 0; }

    // --- Partido: los que descansan juegan al fútbol. Cada equipo ataca una portería; el más cercano va a por la pelota,
    // los demás se colocan (con portero si son tres o más) y al marcar lo celebran
    bool fieldOn; double fx0, fy0, fx1, fy1, goalHalf, goalPause;
    public int ScoreA, ScoreB;
    public Action<int, int, int> OnGoal;
    public void SetField(double x0, double y0, double x1, double y1, double gh) {
      fieldOn = true; fx0 = x0; fy0 = y0; fx1 = x1; fy1 = y1; goalHalf = gh;
      if (ball != null && (bx < x0 || bx > x1 || by < y0 || by > y1)) { bx = (x0 + x1) / 2; by = (y0 + y1) / 2; bvx = bvy = 0; }
    }
    public void ClearField() { fieldOn = false; foreach (var a in actors.Values) a.Team = -1; }
    public void SetMatch(int[] keys, int[] teams) {
      var on = new HashSet<int>();
      for (int i = 0; i < keys.Length; i++) {
        StageActor a; if (!actors.TryGetValue(keys[i], out a)) continue;
        on.Add(keys[i]);
        if (a.Team != teams[i]) { a.Team = teams[i]; a.Walking = false; }
      }
      foreach (var a in actors.Values) if (a.Team >= 0 && !on.Contains(a.Key)) { a.Team = -1; a.Moving = false; }
    }
    void StepMatch(double dt) {
      if (!fieldOn || ball == null) return;
      double cx = (fx0 + fx1) / 2, cy = (fy0 + fy1) / 2;
      if (goalPause > 0) { goalPause -= dt; if (goalPause <= 0) { bx = cx; by = cy; bvx = bvy = 0; } }
      var chaser = new StageActor[2]; var best = new double[] { 1e9, 1e9 };
      var count = new int[2]; var idx = new Dictionary<StageActor, int>();
      foreach (var a in actors.Values) {
        if (a.Team < 0 || (dragging && a == pressed) || a.LandLeft > 0) continue;
        idx[a] = count[a.Team]++;
        double d = Math.Abs(a.X - bx) + Math.Abs(a.Y - by);
        if (d < best[a.Team]) { best[a.Team] = d; chaser[a.Team] = a; }
      }
      foreach (var kv in idx) {
        var a = kv.Key; int i = kv.Value, n = count[a.Team];
        a.KickCd -= dt; if (a.CeleLeft > 0) a.CeleLeft -= dt;
        double own = a.Team == 0 ? fx0 : fx1, opp = a.Team == 0 ? fx1 : fx0, dir = a.Team == 0 ? 1 : -1;
        double tx, ty, speed;
        if (goalPause > 0) { tx = a.X; ty = a.Y; speed = 0; }
        else if (a == chaser[a.Team] && !(n >= 3 && i == 0)) {
          // Detrás de la pelota, mirando a la portería contraria
          double gx = opp - bx, gy = cy - by, gd = Math.Sqrt(gx * gx + gy * gy) + 0.01;
          tx = bx - gx / gd * 3; ty = by - gy / gd * 3 + 1; speed = 24;
          if (Math.Abs(a.X - bx) < 5 && Math.Abs(a.Y - 1 - by) < 4 && a.KickCd <= 0) Kick(a, opp, cy);
        } else if (n >= 3 && i == 0) {
          tx = own + dir * 5; ty = Math.Max(cy - goalHalf, Math.Min(cy + goalHalf, by + 1)); speed = 16;
          if (Math.Abs(a.X - bx) < 5 && Math.Abs(a.Y - 1 - by) < 4 && a.KickCd <= 0) Kick(a, opp, cy);
        } else {
          double lane = (i + 1.0) / (n + 1.0);
          tx = own + (opp - own) * (0.3 + 0.3 * (i % 2)) + (bx - cx) * 0.4; ty = fy0 + (fy1 - fy0) * lane + (by - cy) * 0.3; speed = 15;
        }
        tx = Math.Max(fx0 + 2, Math.Min(fx1 - 2, tx)); ty = Math.Max(fy0 + 4, Math.Min(fy1 + 2, ty));
        double dx = tx - a.X, dy = ty - a.Y, dd = Math.Sqrt(dx * dx + dy * dy), st = speed * dt;
        a.Moving = dd > 0.8 && speed > 0;
        if (a.Moving) { if (dd <= st) { a.X = tx; a.Y = ty; } else { a.X += dx / dd * st; a.Y += dy / dd * st; } if (Math.Abs(dx) > 0.3) a.Left = dx < 0; }
        else a.Left = bx < a.X;
      }
    }
    void Kick(StageActor a, double opp, double cy) {
      double tx = opp, ty = cy + (rnd.NextDouble() * 2 - 1) * (goalHalf - 2);
      // A veces pasa a un compañero que esté más adelantado
      if (rnd.NextDouble() < 0.3) foreach (var m in actors.Values) if (m != a && m.Team == a.Team && Math.Abs(opp - m.X) < Math.Abs(opp - a.X) - 10) { tx = m.X; ty = m.Y - 1; break; }
      double vx = tx - bx, vy = ty - by, vd = Math.Sqrt(vx * vx + vy * vy) + 0.01, pw = 55 + rnd.NextDouble() * 35;
      bvx = vx / vd * pw; bvy = vy / vd * pw * 0.8; a.KickCd = 0.7;
    }
    void Goal(int team) {
      if (team == 0) ScoreA++; else ScoreB++;
      goalPause = 2.6; bvx = bvy = 0;
      foreach (var a in actors.Values) {
        if (a.Team < 0) continue;
        if (a.Team == team) { a.CeleLeft = 2.6; if (GreetFrames != null) ShowEmo(a, CheerFrames ?? GreetFrames, 2.4); }
        else if (SadFrames != null) ShowEmo(a, SadFrames, 2.2);
      }
      if (OnGoal != null) { try { OnGoal(team, ScoreA, ScoreB); } catch { } }
    }
    public BitmapSource[] CheerFrames, SadFrames;

    public void SetBlink(int key, BitmapSource[] blink) { StageActor a; if (actors.TryGetValue(key, out a)) a.Blink = blink; }
    public void SetWalk(int key, BitmapSource[] walk) { StageActor a; if (actors.TryGetValue(key, out a)) a.Walk = walk; }
    // Emociones que le salen solas de vez en cuando, según cómo está
    public void SetMoods(int key, BitmapSource[][] moods) { StageActor a; if (actors.TryGetValue(key, out a)) a.Moods = moods; }
    public void Emote(int key, BitmapSource[] frames, double seconds) { StageActor a; if (actors.TryGetValue(key, out a)) ShowEmo(a, frames, seconds); }
    void ShowEmo(StageActor a, BitmapSource[] frames, double seconds) {
      if (frames == null || frames.Length == 0) return;
      a.EmoFrames = frames; a.EmoLeft = seconds; a.EmoT = 0; a.NextEmo = 6 + rnd.NextDouble() * 10;
    }
    public void Remove(int key) {
      StageActor a; if (!actors.TryGetValue(key, out a)) return;
      canvas.Children.Remove(a.Img); canvas.Children.Remove(a.Emo); canvas.Children.Remove(a.Mark); if (a.Tag != null) canvas.Children.Remove(a.Tag);
      actors.Remove(key);
      if (pressed == a) { pressed = null; dragging = false; }
    }
    public void Clear() { foreach (var k in Keys()) Remove(k); }

    // --- Decorado vivo
    public void AddProp(string id, BitmapSource[] frames, double x, double y, double ax, double ay, double period, int z) {
      RemoveProp(id);
      var p = new StageProp { Frames = frames, X = x, Y = y, AX = ax, AY = ay, Period = period, Z = z, T = rnd.NextDouble() * 3 };
      p.Img = new System.Windows.Controls.Image { Stretch = Stretch.Fill, IsHitTestVisible = false };
      if (frames != null && frames.Length > 0) { p.Img.Width = frames[0].PixelWidth; p.Img.Height = frames[0].PixelHeight; }
      p.Flip = new ScaleTransform(1, 1, ax, 0); p.Img.RenderTransform = p.Flip;
      canvas.Children.Add(p.Img); props[id] = p;
      DrawProp(p);
    }
    // Ruta en tríos x, y, pausa (s); con wrap, al acabar vuelve a empezar desde el primer punto sin andar
    public void PropPath(string id, double[] pts, double speed, bool wrap, bool canFlip) {
      StageProp p; if (!props.TryGetValue(id, out p)) return;
      p.Path = new List<double[]>();
      for (int i = 0; i + 2 < pts.Length; i += 3) p.Path.Add(new double[] { pts[i], pts[i + 1], pts[i + 2] });
      p.Speed = speed; p.Wrap = wrap; p.CanFlip = canFlip; p.Idx = 0;
    }
    // Cuando un Claude se acerca: otros fotogramas (puerta abierta, gato ronroneando) y, si se pide, se queda quieto
    public void PropSensor(string id, BitmapSource[] near, double radius, bool stopNear) {
      StageProp p; if (!props.TryGetValue(id, out p)) return;
      p.Near = near; p.Radius = radius; p.StopNear = stopNear;
    }
    // Al pasar cerca de un Claude le da un susto (el robot aspirador)
    public void PropStartle(string id, BitmapSource[] emote, double radius) {
      StageProp p; if (!props.TryGetValue(id, out p)) return;
      p.Startle = emote; p.StartleRadius = radius;
    }
    public double PropX(string id) { StageProp p; return props.TryGetValue(id, out p) ? p.X : -1; }
    public double PropY(string id) { StageProp p; return props.TryGetValue(id, out p) ? p.Y : -1; }
    // Se va andando hasta x,y y desaparece (los que pausas salen por la puerta)
    public void Leave(int key, double x, double y, BitmapSource[] walk) {
      StageActor a; if (!actors.TryGetValue(key, out a)) return;
      if (walk != null) a.Walk = walk;
      a.TX = x; a.TY = y; a.Walking = true; a.Leaving = true; a.Speed = 12;
      if (a.Tag != null) a.Tag.Visibility = Visibility.Collapsed;
    }

    // --- Pelota: rueda, frena, rebota en los bordes y en los Claudes; se puede chutar pulsándola
    System.Windows.Controls.Image ball; BitmapSource[] ballFrames; double bx, by, bvx, bvy, broll;
    public BitmapSource[] BallHitFrames;
    public double BallX { get { return ball == null ? -1 : bx; } }
    public double BallY { get { return ball == null ? -1 : by; } }
    public void SetBall(BitmapSource[] frames, double x, double y) {
      ClearBall();
      ballFrames = frames; bx = x; by = y; bvx = bvy = 0;
      ball = new System.Windows.Controls.Image { Width = frames[0].PixelWidth, Height = frames[0].PixelHeight, Stretch = Stretch.Fill, Cursor = System.Windows.Input.Cursors.Hand, Source = frames[0] };
      ball.MouseDown += (s, e) => { double ang = rnd.NextDouble() * Math.PI * 2; bvx = Math.Cos(ang) * 75; bvy = Math.Sin(ang) * 55; e.Handled = true; };
      canvas.Children.Add(ball);
      DrawBall();
    }
    public void ClearBall() { if (ball != null) { canvas.Children.Remove(ball); ball = null; } }
    void StepBall(double dt) {
      if (ball == null) return;
      foreach (var a in actors.Values) {
        if ((dragging && a == pressed) || (a.Team >= 0 && fieldOn)) continue;
        double dx = bx - a.X, dy = by - (a.Y - 1), d = Math.Sqrt(dx * dx + dy * dy);
        if (d >= 6 || d < 0.01) continue;
        double nx = dx / d, ny = dy / d;
        if (a.Walking) {
          // Al pasar andando, la empuja hacia donde va
          double wx = a.TX - a.X, wy = a.TY - a.Y, wd = Math.Sqrt(wx * wx + wy * wy) + 0.01;
          bvx = (wx / wd) * 55 + nx * 20; bvy = (wy / wd) * 40 + ny * 15;
        } else {
          double sp = Math.Sqrt(bvx * bvx + bvy * bvy);
          if (sp > 25 && BallHitFrames != null && a.EmoLeft <= 0) ShowEmo(a, BallHitFrames, 1.5);
          bvx = nx * Math.Max(sp * 0.7, 12); bvy = ny * Math.Max(sp * 0.7, 9);
        }
        bx = a.X + nx * 6; by = a.Y - 1 + ny * 6;
      }
      bx += bvx * dt; by += bvy * dt;
      if (fieldOn && goalPause <= 0) {
        double cy = (fy0 + fy1) / 2;
        if (bx < fx0) { if (Math.Abs(by - cy) < goalHalf) { bx = fx0 - 3; Goal(1); } else { bx = fx0; bvx = Math.Abs(bvx) * 0.8; } }
        if (bx > fx1) { if (Math.Abs(by - cy) < goalHalf) { bx = fx1 + 3; Goal(0); } else { bx = fx1; bvx = -Math.Abs(bvx) * 0.8; } }
        if (by < fy0) { by = fy0; bvy = Math.Abs(bvy) * 0.8; } if (by > fy1) { by = fy1; bvy = -Math.Abs(bvy) * 0.8; }
      }
      if (bx < MinX) { bx = MinX; bvx = Math.Abs(bvx) * 0.8; } if (bx > MaxX) { bx = MaxX; bvx = -Math.Abs(bvx) * 0.8; }
      if (by < MinY) { by = MinY; bvy = Math.Abs(bvy) * 0.8; } if (by > MaxY) { by = MaxY; bvy = -Math.Abs(bvy) * 0.8; }
      double f = Math.Pow(0.35, dt); bvx *= f; bvy *= f;
      broll += Math.Sqrt(bvx * bvx + bvy * bvy) * dt;
      DrawBall();
    }
    void DrawBall() {
      var src = ballFrames[(int)(broll / 2.5) % ballFrames.Length];
      if (!ReferenceEquals(ball.Source, src)) ball.Source = src;
      System.Windows.Controls.Canvas.SetLeft(ball, Math.Round(bx - ball.Width / 2)); System.Windows.Controls.Canvas.SetTop(ball, Math.Round(by - ball.Height + 1));
      System.Windows.Controls.Panel.SetZIndex(ball, (int)Math.Round(by) * 10 + 3);
    }

    // --- Huellas en la arena que se borran poco a poco
    public BitmapSource FootFrame; public double FootMinY = 1e9;
    readonly List<System.Windows.Controls.Image> feet = new List<System.Windows.Controls.Image>();
    readonly List<double> footLife = new List<double>();
    int footNext;
    public void ClearFeet() { foreach (var f in feet) canvas.Children.Remove(f); feet.Clear(); footLife.Clear(); footNext = 0; }
    void Foot(double x, double y) {
      if (FootFrame == null) return;
      System.Windows.Controls.Image f;
      if (feet.Count < 40) { f = new System.Windows.Controls.Image { Width = FootFrame.PixelWidth, Height = FootFrame.PixelHeight, Source = FootFrame, IsHitTestVisible = false }; canvas.Children.Add(f); feet.Add(f); footLife.Add(0); footNext = feet.Count - 1; }
      else { footNext = (footNext + 1) % feet.Count; f = feet[footNext]; }
      System.Windows.Controls.Canvas.SetLeft(f, Math.Round(x)); System.Windows.Controls.Canvas.SetTop(f, Math.Round(y)); System.Windows.Controls.Panel.SetZIndex(f, 0);
      footLife[footNext] = 6; f.Opacity = 1;
    }
    void StepFeet(double dt) {
      for (int i = 0; i < feet.Count; i++) {
        if (footLife[i] <= 0) continue;
        footLife[i] -= dt; feet[i].Opacity = Math.Max(0, footLife[i] / 6);
      }
    }

    public void SetPropFrames(string id, BitmapSource[] frames) { StageProp p; if (props.TryGetValue(id, out p)) { p.Frames = frames; DrawProp(p); } }
    public void RemoveProp(string id) { StageProp p; if (props.TryGetValue(id, out p)) { canvas.Children.Remove(p.Img); props.Remove(id); } }
    public void ClearProps() { foreach (var id in new List<string>(props.Keys)) RemoveProp(id); }

    void Step() {
      var now = DateTime.Now; double dt = Math.Min(0.25, (now - last).TotalSeconds); last = now;
      foreach (var a in actors.Values) {
        a.T += dt;
        bool held = dragging && a == pressed;
        if (a.LandLeft > 0) a.LandLeft -= dt;
        else if (a.Walking && !held && a.Team < 0) {
          double dx = a.TX - a.X, dy = a.TY - a.Y, d = Math.Sqrt(dx * dx + dy * dy), st = a.Speed * dt;
          if (Math.Abs(dx) > 0.3) a.Left = dx < 0;
          if (d <= st) { a.X = a.TX; a.Y = a.TY; a.Walking = false; a.T = 0; }
          else { a.X += dx / d * st; a.Y += dy / d * st; }
          if (a.Y > FootMinY && (a.FootD += st) > 4) { a.FootD = 0; a.FootL = !a.FootL; Foot(a.X + (a.FootL ? -3 : 1), a.Y - 1); }
        }
        // Parpadeo y emociones espontáneas
        if (a.BlinkLeft > 0) a.BlinkLeft -= dt;
        else if ((a.NextBlink -= dt) <= 0) { a.BlinkLeft = 0.16; a.NextBlink = 2.5 + rnd.NextDouble() * 4; }
        if (a.EmoLeft > 0) { a.EmoLeft -= dt; a.EmoT += dt; }
        else if (!held && a.Moods != null && a.Moods.Length > 0 && (a.NextEmo -= dt) <= 0) ShowEmo(a, a.Moods[rnd.Next(a.Moods.Length)], 2.2 + rnd.NextDouble());
      }
      // Dos que se cruzan andando se saludan (una vez cada rato)
      if (GreetFrames != null) {
        foreach (var a in actors.Values) {
          if (!a.Walking) continue;
          foreach (var b in actors.Values) {
            if (a == b || Math.Abs(a.X - b.X) > 13 || Math.Abs(a.Y - b.Y) > 9) continue;
            long k = Math.Min(a.Key, b.Key) * 100000000L + Math.Max(a.Key, b.Key);
            DateTime t; if (greeted.TryGetValue(k, out t) && (now - t).TotalSeconds < 40) continue;
            greeted[k] = now; ShowEmo(a, GreetFrames, 1.8); ShowEmo(b, GreetFrames, 1.8);
          }
        }
      }
      StepMatch(dt);
      foreach (var a in actors.Values) Draw(a);
      foreach (var k in Keys()) { var a = actors[k]; if (a.Leaving && !a.Walking) Remove(k); }
      foreach (var p in props.Values) StepProp(p, dt);
      StepBall(dt); StepFeet(dt);
    }
    StageActor Nearest(double x, double y, double r) {
      foreach (var a in actors.Values) if (Math.Abs(a.X - x) < r && Math.Abs(a.Y - y) < r * 0.8) return a;
      return null;
    }
    void StepProp(StageProp p, double dt) {
      p.T += dt;
      p.IsNear = p.Near != null && Nearest(p.X, p.Y, p.Radius) != null;
      if (p.Startle != null) { var a = Nearest(p.X, p.Y, p.StartleRadius); if (a != null && a.EmoLeft <= 0 && !a.Walking) ShowEmo(a, p.Startle, 1.6); }
      if (p.Path != null && p.Path.Count > 0 && !(p.IsNear && p.StopNear)) {
        if (p.Wait > 0) p.Wait -= dt;
        else {
          var tg = p.Path[p.Idx];
          double dx = tg[0] - p.X, dy = tg[1] - p.Y, d = Math.Sqrt(dx * dx + dy * dy), st = p.Speed * dt;
          if (Math.Abs(dx) > 0.2) p.Left = dx < 0;
          if (d <= st) {
            p.X = tg[0]; p.Y = tg[1]; p.Wait = tg[2]; p.Idx++;
            if (p.Idx >= p.Path.Count) { p.Idx = 0; if (p.Wrap) { p.X = p.Path[0][0]; p.Y = p.Path[0][1]; p.Idx = p.Path.Count > 1 ? 1 : 0; } }
          } else { p.X += dx / d * st; p.Y += dy / d * st; }
        }
      }
      DrawProp(p);
    }
    void DrawProp(StageProp p) {
      var fr = p.IsNear ? p.Near : p.Frames;
      if (fr == null || fr.Length == 0) return;
      var src = fr[(int)(p.T / p.Period) % fr.Length];
      if (!ReferenceEquals(p.Img.Source, src)) p.Img.Source = src;
      double sx = p.CanFlip && p.Left ? -1 : 1; if (p.Flip.ScaleX != sx) p.Flip.ScaleX = sx;
      double l = Math.Round(p.X - p.AX), t = Math.Round(p.Y - p.AY);
      if (System.Windows.Controls.Canvas.GetLeft(p.Img) != l) System.Windows.Controls.Canvas.SetLeft(p.Img, l);
      if (System.Windows.Controls.Canvas.GetTop(p.Img) != t) System.Windows.Controls.Canvas.SetTop(p.Img, t);
      int z = p.Z >= 0 ? p.Z : (int)Math.Round(p.Y) * 10 + 5;
      if (System.Windows.Controls.Panel.GetZIndex(p.Img) != z) System.Windows.Controls.Panel.SetZIndex(p.Img, z);
    }
    void Draw(StageActor a) {
      BitmapSource[] fr; double period; bool flip = false, held = dragging && a == pressed;
      if (held) { fr = a.Drag; period = 0.18; }
      else if (a.LandLeft > 0 && a.Land != null) { fr = a.Land; period = 0.2; }
      else if (a.Team >= 0 && a.Run != null) {
        if (a.CeleLeft > 0 || (goalPause > 0 && a.Cele != null && a.CeleLeft > 0)) { fr = a.Cele; period = 0.15; }
        else if (a.Moving) { fr = a.Run; period = 0.1; flip = a.Left; }
        else { fr = a.Ready; period = 0.25; flip = a.Left; }
      }
      else if (a.Walking) { fr = a.Walk; period = 0.14; flip = a.Left; }
      else { fr = a.BlinkLeft > 0 && a.Blink != null && a.Blink.Length == a.Act.Length ? a.Blink : a.Act; period = a.Slow ? 0.6 : 0.3; }
      if (fr == null || fr.Length == 0) return;
      var src = fr[((int)(a.T / period) + a.Offset) % fr.Length];
      if (!ReferenceEquals(a.Img.Source, src)) a.Img.Source = src;
      double sx = flip ? -1 : 1; if (a.Flip.ScaleX != sx) a.Flip.ScaleX = sx;
      double l = Math.Round(a.X) - 16, t = Math.Round(a.Y) - 25;
      if (System.Windows.Controls.Canvas.GetLeft(a.Img) != l) System.Windows.Controls.Canvas.SetLeft(a.Img, l);
      if (System.Windows.Controls.Canvas.GetTop(a.Img) != t) System.Windows.Controls.Canvas.SetTop(a.Img, t);
      // Los de más abajo, delante; el que llevas cogido, encima de todo
      int z = (int)Math.Round(a.Y) * 10 + (held ? 100000 : 0);
      if (System.Windows.Controls.Panel.GetZIndex(a.Img) != z) System.Windows.Controls.Panel.SetZIndex(a.Img, z);
      var mk = a.Team >= 0 && TeamMarks != null ? TeamMarks[a.Team] : a.MarkFrame;
      if (!ReferenceEquals(a.Mark.Source, mk)) a.Mark.Source = mk;
      System.Windows.Controls.Canvas.SetLeft(a.Mark, Math.Round(a.X) - 8); System.Windows.Controls.Canvas.SetTop(a.Mark, Math.Round(a.Y) - 3 + (held ? 6 : 0));
      System.Windows.Controls.Panel.SetZIndex(a.Mark, held ? 99999 : z - 2);
      if (a.Tag != null) {
        double tl = Math.Round(a.X - a.Tag.ActualWidth / 2), tt = Math.Round(a.Y) + 1;
        if (System.Windows.Controls.Canvas.GetLeft(a.Tag) != tl) System.Windows.Controls.Canvas.SetLeft(a.Tag, tl);
        if (System.Windows.Controls.Canvas.GetTop(a.Tag) != tt) System.Windows.Controls.Canvas.SetTop(a.Tag, tt);
      }
      // Bocadillo de emoción encima de la cabeza, con un saltito al salir
      if (a.EmoLeft > 0 && a.EmoFrames != null) {
        var es = a.EmoFrames[(int)(a.EmoT / 0.25) % a.EmoFrames.Length];
        if (!ReferenceEquals(a.Emo.Source, es)) a.Emo.Source = es;
        double pop = a.EmoT < 0.12 ? 2 : 0;
        System.Windows.Controls.Canvas.SetLeft(a.Emo, Math.Round(a.X) - 2); System.Windows.Controls.Canvas.SetTop(a.Emo, Math.Round(a.Y) - 38 + pop);
        if (a.Emo.Visibility != Visibility.Visible) a.Emo.Visibility = Visibility.Visible;
      } else if (a.Emo.Visibility != Visibility.Collapsed) a.Emo.Visibility = Visibility.Collapsed;
    }
    StageActor Find(object img) { foreach (var a in actors.Values) if (ReferenceEquals(a.Img, img)) return a; return null; }
    // Pulsar y soltar sin mover = clic (lo atiende PowerShell); mover con el botón pulsado = arrastrar
    void Down(object s, System.Windows.Input.MouseButtonEventArgs e) {
      if (e.ChangedButton != System.Windows.Input.MouseButton.Left) return;
      pressed = Find(s); if (pressed == null) return;
      pressPt = e.GetPosition(canvas); grabX = pressed.X - pressPt.X; grabY = pressed.Y - pressPt.Y; dragging = false;
      ((UIElement)s).CaptureMouse();
    }
    void Move(object s, System.Windows.Input.MouseEventArgs e) {
      if (pressed == null || e.LeftButton != System.Windows.Input.MouseButtonState.Pressed) return;
      var p = e.GetPosition(canvas);
      if (!dragging) {
        if (Math.Abs(p.X - pressPt.X) + Math.Abs(p.Y - pressPt.Y) < 3) return;
        dragging = true; pressed.Walking = false; pressed.T = 0;
        ShowEmo(pressed, ScaredFrames, 600);
      }
      pressed.X = Math.Max(MinX, Math.Min(MaxX, p.X + grabX)); pressed.Y = Math.Max(MinY, Math.Min(MaxY, p.Y + grabY));
      Draw(pressed);
    }
    void Up(object s, System.Windows.Input.MouseButtonEventArgs e) {
      if (e.ChangedButton != System.Windows.Input.MouseButton.Left || pressed == null) return;
      var a = pressed; bool was = dragging; pressed = null; dragging = false;
      ((UIElement)s).ReleaseMouseCapture();
      if (!was) return;
      e.Handled = true;
      a.TX = a.X; a.TY = a.Y; a.Walking = false; a.T = 0; a.LandLeft = a.Land != null ? 1.3 : 0;
      ShowEmo(a, DizzyFrames, 2.2);
      Draw(a);
      if (OnDrop != null) { try { OnDrop(a.Key, a.X, a.Y); } catch { } }
    }
  }

  // Diario: cada petición que hiciste en una sesión y lo que Claude hizo con ella (archivos, comandos, tiempo).
  // Se lee de los registros de Claude Code (~/.claude/projects/*/<sesión>.jsonl), solo lo nuevo desde la última lectura.
  public class DiaryTurn {
    public DateTime Start; public DateTime End; public string Text = "";
    public List<string> Files = new List<string>(); public int Commands, Agents, Tools;
    public string When { get; set; } public string Prompt { get; set; } public string Detail { get; set; }
  }
  public class DiarySession {
    public string Id { get; set; } public string Title { get; set; } public string Cwd { get; set; } public string Folder { get; set; }
    public DateTime Last { get; set; } public string LastText { get; set; } public string Summary { get; set; }
    public string Color { get; set; } public bool Open { get; set; } public bool IsExpanded { get; set; }
    public List<DiaryTurn> Turns { get; set; }
    public string Key { get; set; }                 // sesión + día, para recordar qué está abierto
    public List<DiaryTurn> Raw = new List<DiaryTurn>();
  }
  // Un día del diario: su subtítulo y las sesiones con lo que hicieron ese día
  public class DiaryDay {
    public string Header { get; set; } public string Sub { get; set; }
    public List<DiarySession> Sessions { get; set; }
  }
  // Lo leído de cada registro: hasta dónde y qué peticiones salieron. Se guarda en disco para no releer nunca lo mismo.
  public class DiaryFile {
    public long Offset; public long Length; public string Id, Title, Custom, Cwd;
    public List<DiaryTurn> Turns = new List<DiaryTurn>();
    [ScriptIgnore] public DiaryTurn Cur;
  }
  public static class Diary {
    static Dictionary<string, DiaryFile> cache;
    static readonly object gate = new object();
    // Al cerrar el diario se suelta todo: lo leído ya está guardado en disco y se recupera al volver a abrirlo
    public static void Release() { lock (gate) { cache = null; } }
    static readonly CultureInfo es = new CultureInfo("es-ES");
    const long FirstReadMax = 512L << 20;  // la primera vez, como mucho los últimos 512 MB de cada registro
    static byte[] P(string s) { return Encoding.ASCII.GetBytes(s); }
    static readonly byte[] patToolUse = P("\"type\":\"tool_use\"");
    static readonly Regex reName = new Regex("\"name\":\"([^\"]+)\"");
    static readonly Regex rePath = new Regex("\"(?:file_path|notebook_path)\":\"((?:[^\"\\\\]|\\\\.)*)\"");
    static readonly Regex reTime = new Regex("\"timestamp\":\"([^\"]+)\"");
    static readonly Regex reCwd = new Regex("\"cwd\":\"((?:[^\"\\\\]|\\\\.)*)\"");
    static readonly JavaScriptSerializer js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 };

    public static Task<List<DiarySession>> LoadAsync(string root, string cacheFile, int days) { return Task.Run(() => Load(root, cacheFile, days)); }
    public static List<DiarySession> Load(string root, string cacheFile, int days) {
      lock (gate) {
        if (cache == null) cache = ReadCache(cacheFile);
        var list = new List<DiarySession>();
        DateTime since = DateTime.Now.AddDays(-days);
        bool changed = false;
        if (!Directory.Exists(root)) return list;
        foreach (var dir in Directory.GetDirectories(root))
          foreach (var f in Directory.GetFiles(dir, "*.jsonl")) {
            var fi = new FileInfo(f);
            if (fi.LastWriteTime < since) continue;
            DiaryFile st;
            if (!cache.TryGetValue(f, out st) || fi.Length < st.Offset) { st = new DiaryFile { Id = Path.GetFileNameWithoutExtension(f) }; cache[f] = st; }
            if (fi.Length > st.Offset) {
              try { Read(f, st); } catch { }
              st.Length = fi.Length; changed = true;
            }
            if (st.Turns.Count > 0) list.Add(Snapshot(st, since));
          }
        if (changed) WriteCache(cacheFile);
        list.RemoveAll(x => x.Raw.Count == 0);
        list.Sort((a, b) => b.Last.CompareTo(a.Last));
        return list;
      }
    }
    static Dictionary<string, DiaryFile> ReadCache(string file) {
      try {
        if (File.Exists(file)) {
          var c = js.Deserialize<Dictionary<string, DiaryFile>>(File.ReadAllText(file, Encoding.UTF8));
          foreach (var st in c.Values) {
            foreach (var t in st.Turns) { t.Start = t.Start.ToLocalTime(); t.End = t.End.ToLocalTime(); }
            // La última petición puede seguir en marcha: lo que haga después se le sigue sumando
            if (st.Turns.Count > 0) st.Cur = st.Turns[st.Turns.Count - 1];
          }
          return c;
        }
      } catch { }
      return new Dictionary<string, DiaryFile>();
    }
    static void WriteCache(string file) {
      try {
        // Solo lo de los últimos 14 días y como mucho 150 peticiones por sesión
        var keep = new Dictionary<string, DiaryFile>();
        DateTime old = DateTime.Now.AddDays(-14);
        foreach (var kv in cache) {
          var st = kv.Value;
          if (st.Turns.Count > 400) st.Turns.RemoveRange(0, st.Turns.Count - 400);
          if (st.Turns.Count > 0 && st.Turns[st.Turns.Count - 1].End < old && File.Exists(kv.Key) && new FileInfo(kv.Key).LastWriteTime < old) continue;
          keep[kv.Key] = st;
        }
        File.WriteAllText(file + ".tmp", js.Serialize(keep), Encoding.UTF8);
        if (File.Exists(file)) File.Delete(file);
        File.Move(file + ".tmp", file);
      } catch { }
    }

    // Recorre el registro línea a línea sin cargarlo entero; de cada línea solo se descodifica lo que hace falta
    static void Read(string path, DiaryFile st) {
      using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16)) {
        long from = st.Offset;
        bool skipPartial = false;
        if (from == 0 && fs.Length > FirstReadMax) { from = fs.Length - FirstReadMax; skipPartial = true; }
        fs.Seek(from, SeekOrigin.Begin);
        var buf = new byte[1 << 20];
        var line = new MemoryStream();
        long pos = from, lineStart = from;
        int n;
        while ((n = fs.Read(buf, 0, buf.Length)) > 0) {
          int s = 0;
          for (int i = 0; i < n; i++) {
            if (buf[i] != 10) continue;
            line.Write(buf, s, i - s);
            if (!skipPartial && line.Length > 2) { try { Line(line.GetBuffer(), (int)line.Length, st); } catch { } }
            skipPartial = false;
            line.SetLength(0);
            s = i + 1;
            lineStart = pos + i + 1;
          }
          line.Write(buf, s, n - s);
          pos += n;
        }
        st.Offset = lineStart;   // una línea a medio escribir se lee la próxima vez
      }
    }
    static int IndexOf(byte[] a, int from, int to, byte[] p) {
      for (int i = from; i <= to - p.Length; i++) {
        if (a[i] != p[0]) continue;
        int k = 1; while (k < p.Length && a[i + k] == p[k]) k++;
        if (k == p.Length) return i;
      }
      return -1;
    }
    static string Str(byte[] a, int off, int len) { return Encoding.UTF8.GetString(a, off, Math.Max(0, len)); }
    static string Unescape(string raw) { try { return js.Deserialize<string>("\"" + raw + "\""); } catch { return raw; } }
    static object Get(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) ? v : null; }

    static readonly Regex rePaste = new Regex("<pasted_content[^>]*>([\\s\\S]*?)(?:</pasted_content>|$)");
    static readonly Regex reCmdName = new Regex("<command-name>([\\s\\S]*?)</command-name>");
    static readonly Regex reCmdArgs = new Regex("<command-args>([\\s\\S]*?)</command-args>");
    // Comandos de Claude Code que no son trabajo: no salen en el diario
    static readonly HashSet<string> plainCommands = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
      "/clear", "/compact", "/model", "/config", "/help", "/exit", "/quit", "/resume", "/login", "/logout", "/status", "/cost",
      "/context", "/mcp", "/plugin", "/plugins", "/chrome", "/fast", "/permissions", "/memory", "/doctor", "/ide", "/theme",
      "/vim", "/usage", "/rename", "/hooks", "/agents", "/output-style", "/statusline", "/terminal-setup", "/upgrade", "/feedback", "/rewind", "/export" };
    // El texto de una petición tal como se ve en el diario, o null si no es una petición tuya
    static string Clean(string text) {
      if (text == null) return null;
      text = text.Trim();
      if (text.Length == 0 || text.StartsWith("[Request interrupted") || text.StartsWith("This session is being continued from a previous conversation")) return null;
      // Comandos (/autonomo, /despierto...): el nombre y lo que le pasaste
      if (text.StartsWith("<command-")) {
        var nm = reCmdName.Match(text);
        if (!nm.Success) return null;
        string name = nm.Groups[1].Value.Trim();
        if (plainCommands.Contains(name)) return null;
        var am = reCmdArgs.Match(text);
        return (name + " " + (am.Success ? am.Groups[1].Value.Trim() : "")).Trim();
      }
      // Texto pegado: lo que escribiste tú, o el principio de lo pegado si no escribiste nada más
      if (text.Contains("<pasted_content")) {
        var pm = rePaste.Match(text);
        string own = rePaste.Replace(text, " ").Trim();
        if (own.Length > 0) return own + "  (+ texto pegado)";
        return pm.Success && pm.Groups[1].Value.Trim().Length > 0 ? "📋 " + pm.Groups[1].Value.Trim() : null;
      }
      if (text.StartsWith("<")) return null;   // avisos de tareas, salida de comandos locales...
      return text;
    }

    static void Line(byte[] a, int len, DiaryFile st) {
      string head = Str(a, 0, Math.Min(len, 700));
      if (head.StartsWith("{\"type\":\"ai-title\"") || head.StartsWith("{\"type\":\"custom-title\"")) {
        if (len > 20000) return;
        var t = js.Deserialize<Dictionary<string, object>>(Str(a, 0, len));
        if (Get(t, "aiTitle") is string) st.Title = (string)Get(t, "aiTitle");
        if (Get(t, "customTitle") is string) st.Custom = (string)Get(t, "customTitle");
        return;
      }
      if (head.StartsWith("{\"type\":")) return;                 // registros internos (peticiones a la API, modos...)
      if (head.Contains("\"isSidechain\":true")) return;         // subagentes
      bool asst = head.Contains("\"role\":\"assistant\"");
      bool user = !asst && (head.Contains("\"type\":\"user\"") || head.Contains("\"role\":\"user\""));
      if (!asst && !user) return;
      // La fecha y la carpeta van al final de la línea
      string tail = Str(a, Math.Max(0, len - 2000), Math.Min(len, 2000));
      DateTime ts = DateTime.MinValue;
      var tm = reTime.Matches(tail);
      if (tm.Count > 0 && DateTime.TryParse(tm[tm.Count - 1].Groups[1].Value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out ts)) ts = ts.ToLocalTime();
      var cm = reCwd.Match(tail);
      if (cm.Success) st.Cwd = Unescape(cm.Groups[1].Value);
      var cur = st.Cur;
      if (user) {
        // Las líneas enormes (capturas pegadas) también son peticiones: solo se descartan las absurdas
        if (head.Contains("\"tool_use_id\"") || head.Contains("\"type\":\"tool_result\"") || len > (64 << 20)) { if (cur != null && ts > cur.End) cur.End = ts; return; }
        var d = js.Deserialize<Dictionary<string, object>>(Str(a, 0, len));
        if (Get(d, "isMeta") is bool && (bool)Get(d, "isMeta")) return;
        var content = Get(Get(d, "message") as Dictionary<string, object>, "content");
        string text = null;
        if (content is string) text = (string)content;
        else if (content is System.Collections.IList) {
          var sb = new StringBuilder();
          foreach (var o in (System.Collections.IList)content) {
            var b = o as Dictionary<string, object>;
            if ((Get(b, "type") as string) == "text" && Get(b, "text") is string) sb.Append((string)Get(b, "text")).Append(' ');
          }
          text = sb.ToString();
        }
        text = Clean(text);
        // Avisos de tareas en segundo plano, salida de comandos...: no son peticiones, pero la petición sigue viva
        if (text == null) { if (cur != null && ts > cur.End) cur.End = ts; return; }
        if (text.Length > 400) text = text.Substring(0, 400);
        st.Cur = new DiaryTurn { Start = ts, End = ts, Text = text };
        st.Turns.Add(st.Cur);
        if (st.Turns.Count > 400) st.Turns.RemoveAt(0);
        return;
      }
      if (cur == null) return;
      if (ts > cur.End) cur.End = ts;
      // Herramientas que usó: solo se mira lo que hay justo detrás de cada "tool_use"
      int at = 0;
      while ((at = IndexOf(a, at, len, patToolUse)) >= 0) {
        string near = Str(a, at, Math.Min(1500, len - at));
        at += patToolUse.Length;
        var nm = reName.Match(near);
        if (!nm.Success) continue;
        string name = nm.Groups[1].Value;
        if (name == "Edit" || name == "Write" || name == "MultiEdit" || name == "NotebookEdit") {
          var pm = rePath.Match(near);
          if (pm.Success) { var fp = Unescape(pm.Groups[1].Value); if (!cur.Files.Contains(fp)) cur.Files.Add(fp); }
        }
        else if (name == "Bash" || name == "PowerShell") cur.Commands++;
        else if (name == "Agent" || name == "Task") cur.Agents++;
        else cur.Tools++;
      }
    }
    public static string Ago(DateTime t) {
      var d = DateTime.Now - t;
      if (d.TotalMinutes < 1) return "ahora";
      if (d.TotalHours < 1) return "hace " + (int)d.TotalMinutes + " min";
      if (t.Date == DateTime.Today) return "hoy " + t.ToString("HH:mm");
      if (t.Date == DateTime.Today.AddDays(-1)) return "ayer " + t.ToString("HH:mm");
      return t.ToString("d MMM HH:mm", es);
    }
    static string Dur(TimeSpan d) {
      if (d.TotalMinutes < 1) return "<1 min";
      if (d.TotalHours < 1) return (int)d.TotalMinutes + " min";
      return (int)d.TotalHours + " h " + d.Minutes.ToString("00") + " min";
    }
    static DiarySession Snapshot(DiaryFile st, DateTime since) {
      var s = new DiarySession { Id = st.Id, Title = st.Custom ?? st.Title, Cwd = st.Cwd ?? "", Color = "#5F6775" };
      s.Folder = string.IsNullOrEmpty(s.Cwd) ? "" : s.Cwd;
      if (string.IsNullOrEmpty(s.Title)) s.Title = string.IsNullOrEmpty(s.Cwd) ? st.Id : Path.GetFileName(s.Cwd.TrimEnd('\\'));
      for (int i = st.Turns.Count - 1; i >= 0; i--) {
        if (st.Turns[i].End < since) break;
        s.Raw.Add(st.Turns[i]);
      }
      if (st.Turns.Count > 0) s.Last = st.Turns[st.Turns.Count - 1].End;
      s.LastText = Ago(s.Last);
      return s;
    }
    // Lo que se enseña de unas peticiones (de la más nueva a la más vieja): cada una con su detalle, y el resumen
    static void Fill(DiarySession s, List<DiaryTurn> raw) {
      s.Turns = new List<DiaryTurn>();
      var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase); int cmds = 0; var work = TimeSpan.Zero; int count = 0;
      foreach (var t in raw) {
        count++;
        foreach (var f in t.Files) files.Add(f);
        cmds += t.Commands; work += t.End - t.Start;
        if (s.Turns.Count >= 100) continue;
        string first = t.Text.Replace("\r", " ").Replace("\n", " ");
        while (first.Contains("  ")) first = first.Replace("  ", " ");
        var parts = new List<string>();
        if (t.Files.Count > 0) {
          var names = new List<string>();
          foreach (var f in t.Files) { var n = Path.GetFileName(f); if (!names.Contains(n)) names.Add(n); }
          string shown = string.Join(", ", names.GetRange(0, Math.Min(3, names.Count)).ToArray());
          parts.Add("✎ " + (names.Count == 1 ? "editó " : "editó " + names.Count + " archivos: ") + shown + (names.Count > 3 ? " +" + (names.Count - 3) : ""));
        }
        if (t.Commands > 0) parts.Add("⌘ " + t.Commands + (t.Commands == 1 ? " comando" : " comandos"));
        if (t.Agents > 0) parts.Add(t.Agents + (t.Agents == 1 ? " subagente" : " subagentes"));
        if (parts.Count == 0) parts.Add(t.Tools > 0 ? "consultó " + t.Tools + (t.Tools == 1 ? " cosa" : " cosas") + ", sin cambios" : "solo respondió");
        parts.Add(Dur(t.End - t.Start));
        s.Turns.Add(new DiaryTurn { Start = t.Start, End = t.End, When = t.Start.ToString("HH:mm"), Prompt = first.Length > 220 ? first.Substring(0, 220) + "…" : first, Detail = string.Join("  ·  ", parts.ToArray()) });
      }
      s.Summary = count + (count == 1 ? " petición" : " peticiones") + "  ·  " + files.Count + (files.Count == 1 ? " archivo" : " archivos") + "  ·  " + cmds + " comandos  ·  " + Dur(work) + " trabajando";
    }

    // El diario por días: cada sesión sale en cada día en que le pediste algo, solo con lo de ese día.
    // Las sesiones llegan ya en el orden en que se enseñan (abiertas primero, luego por actividad).
    public static List<DiaryDay> ByDay(System.Collections.IEnumerable sessions) {
      var byDate = new SortedDictionary<DateTime, List<DiarySession>>();
      foreach (DiarySession s in sessions) {
        var parts = new Dictionary<DateTime, List<DiaryTurn>>();
        foreach (var t in s.Raw) {
          List<DiaryTurn> l;
          if (!parts.TryGetValue(t.Start.Date, out l)) { l = new List<DiaryTurn>(); parts[t.Start.Date] = l; }
          l.Add(t);
        }
        foreach (var kv in parts) {
          var d = new DiarySession { Id = s.Id, Title = s.Title, Cwd = s.Cwd, Folder = s.Folder, Color = s.Color, Open = s.Open, Key = s.Id + "|" + kv.Key.ToString("yyyyMMdd") };
          d.Raw = kv.Value;
          d.Last = kv.Value[0].Start;
          d.LastText = (kv.Value.Count == 1 ? "a las " : "última a las ") + d.Last.ToString("HH:mm");
          Fill(d, kv.Value);
          List<DiarySession> day;
          if (!byDate.TryGetValue(kv.Key, out day)) { day = new List<DiarySession>(); byDate[kv.Key] = day; }
          day.Add(d);
        }
      }
      var days = new List<DiaryDay>();
      foreach (var kv in byDate) {
        var list = kv.Value;
        // Las abiertas primero y, dentro, la que trabajó más tarde ese día
        list.Sort((a, b) => a.Open != b.Open ? (a.Open ? -1 : 1) : b.Last.CompareTo(a.Last));
        int n = 0;
        foreach (var s in list) n += s.Raw.Count;
        string name = kv.Key.ToString("dddd d 'de' MMMM", es);
        string header = kv.Key == DateTime.Today ? "Hoy · " + name : kv.Key == DateTime.Today.AddDays(-1) ? "Ayer · " + name : char.ToUpper(name[0]) + name.Substring(1);
        days.Insert(0, new DiaryDay { Header = header, Sessions = list,
          Sub = list.Count + (list.Count == 1 ? " sesión" : " sesiones") + "  ·  " + n + (n == 1 ? " petición" : " peticiones") });
      }
      return days;
    }
  }

  public class Other {
    public string Name { get; set; }
    public double MB { get; set; }
    public string Mem { get; set; }
    public string Key { get; set; }
    public int Count { get; set; }
    public int[] Pids { get; set; }
    public string Cpu { get; set; }
    public string Mark { get; set; }
    public string Tip { get; set; }
    public string Path { get; set; }
    public bool Protected { get; set; }
  }

  public static class Native {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr info, int len, out int ret);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr info, int len, out int ret);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder sb, ref int size);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemStatus m);
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetConsoleTitleW(StringBuilder sb, uint size);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    struct MemStatus { public uint Length, Load; public ulong Total, Avail, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExtended; }

    static bool With(int pid, int access, Func<IntPtr, bool> act) {
      IntPtr h = OpenProcess(access, false, pid);
      if (h == IntPtr.Zero) return false;
      try { return act(h); } finally { CloseHandle(h); }
    }
    public static bool Suspend(int pid) { return With(pid, 0x0800, h => NtSuspendProcess(h) == 0); }
    public static bool Resume(int pid) { return With(pid, 0x0800, h => NtResumeProcess(h) == 0); }
    // Moves the process's pages out of RAM (to the page file) until it touches them again.
    public static bool Trim(int pid) { return With(pid, 0x0400 | 0x0100, h => EmptyWorkingSet(h)); }
    // The title of the console window the process runs in: what its terminal shows.
    public static string ConsoleTitle(int pid) {
      FreeConsole();
      if (!AttachConsole((uint)pid)) return null;
      var sb = new StringBuilder(1024);
      GetConsoleTitleW(sb, 1024);
      FreeConsole();
      return sb.ToString();
    }

    // The console window of a process; in Windows Terminal it is a hidden window owned by the terminal's.
    public static IntPtr ConsoleWindow(int pid) {
      FreeConsole();
      if (!AttachConsole((uint)pid)) return IntPtr.Zero;
      IntPtr h = GetConsoleWindow();
      FreeConsole();
      return h;
    }
    public static IntPtr Owner(IntPtr h) { return h == IntPtr.Zero ? IntPtr.Zero : GetWindow(h, 4); }
    public static int WindowPid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return (int)p; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    // Coloca una ventana para que su marco visible (sin los bordes invisibles de Windows 11) ocupe x,y,w,h.
    // No toca ventanas maximizadas o minimizadas, ni mientras se arrastra algo con el ratón.
    public static bool PlaceVisible(IntPtr h, int x, int y, int w, int hh) {
      if (h == IntPtr.Zero || IsIconic(h) || IsZoomed(h) || (GetAsyncKeyState(1) & 0x8000) != 0) return false;
      RECT r, f;
      if (!GetWindowRect(h, out r)) return false;
      if (DwmGetWindowAttribute(h, 9, out f, 16) != 0) f = r;
      if (f.L == x && f.T == y && f.R - f.L == w && f.B - f.T == hh) return false;
      int dl = f.L - r.L, dt = f.T - r.T, dr = r.R - f.R, db = r.B - f.B;
      return SetWindowPos(h, IntPtr.Zero, x - dl, y - dt, w + dl + dr, hh + dt + db, 0x0014);
    }
    // Recoge la basura y devuelve a Windows las páginas que no se están usando (vuelven solas si hacen falta)
    public static void Trim() {
      System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
      GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
      using (var me = System.Diagnostics.Process.GetCurrentProcess()) EmptyWorkingSet(me.Handle);
    }
    public static int[] WindowRect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R - r.L, r.B - r.T }; }
    // Saca una ventana de maximizada (y si se pide, de minimizada) para poder colocarla
    public static void Restore(IntPtr h, bool minimized) { if (h != IntPtr.Zero && (IsZoomed(h) || (minimized && IsIconic(h)))) ShowWindow(h, 9); }

    // Acoplado: la ventana no se deja arrastrar, redimensionar ni maximizar (WM_SYSCOMMAND SC_MOVE / SC_SIZE / SC_MAXIMIZE)
    public static bool Locked;
    public static void LockHook(System.Windows.Interop.HwndSource src) { src.AddHook(SysCommand); }
    static IntPtr SysCommand(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
      if (Locked && msg == 0x0112) {
        int cmd = (int)(w.ToInt64() & 0xFFF0);
        if (cmd == 0xF010 || cmd == 0xF000 || cmd == 0xF030) handled = true;
      }
      return IntPtr.Zero;
    }
    public static bool Focus(IntPtr h) {
      if (h == IntPtr.Zero) return false;
      if (IsIconic(h)) ShowWindow(h, 9);
      return SetForegroundWindow(h);
    }

    // Every process in one system call: what WMI took a second of CPU to answer.
    static IntPtr buf = IntPtr.Zero;
    static int bufLen = 1 << 20;
    public static List<Proc> Snapshot() {
      var list = new List<Proc>(512);
      if (IntPtr.Size != 8) return list;
      int ret;
      while (true) {
        if (buf == IntPtr.Zero) buf = Marshal.AllocHGlobal(bufLen);
        int st = NtQuerySystemInformation(5, buf, bufLen, out ret);
        if (st == unchecked((int)0xC0000004)) { Marshal.FreeHGlobal(buf); buf = IntPtr.Zero; bufLen = Math.Max(bufLen * 2, ret + 65536); continue; }
        if (st != 0) return list;
        break;
      }
      long off = 0;
      while (true) {
        IntPtr p = new IntPtr(buf.ToInt64() + off);
        int next = Marshal.ReadInt32(p, 0);
        var pr = new Proc();
        pr.Pid = (int)Marshal.ReadIntPtr(p, 80).ToInt64();
        pr.Ppid = (int)Marshal.ReadIntPtr(p, 88).ToInt64();
        int nameLen = Marshal.ReadInt16(p, 56) & 0xFFFF;
        IntPtr namePtr = Marshal.ReadIntPtr(p, 64);
        pr.Name = namePtr == IntPtr.Zero ? (pr.Pid == 0 ? "Idle" : "System") : Marshal.PtrToStringUni(namePtr, nameLen / 2);
        pr.CpuTime = Marshal.ReadInt64(p, 40) + Marshal.ReadInt64(p, 48);
        long created = Marshal.ReadInt64(p, 32);
        pr.Created = created > 0 ? DateTime.FromFileTime(created) : DateTime.MinValue;
        pr.WorkingSet = Marshal.ReadIntPtr(p, 144).ToInt64();
        list.Add(pr);
        if (next == 0) break;
        off += next;
      }
      return list;
    }

    static readonly Dictionary<int, string> paths = new Dictionary<int, string>();
    public static string ImagePath(int pid, DateTime created) {
      string key = pid + "@" + created.Ticks;
      string known;
      if (paths.TryGetValue(pid, out known) && known.StartsWith(key + "|")) return known.Substring(key.Length + 1);
      string path = "";
      With(pid, 0x1000, h => { var sb = new StringBuilder(1024); int n = 1024; if (QueryFullProcessImageNameW(h, 0, sb, ref n)) path = sb.ToString(); return true; });
      paths[pid] = key + "|" + path;
      return path;
    }

    // The directory the process was started in (its PEB), read from its memory: where the person ran claude.
    public static string StartDir(int pid) {
      string result = null;
      With(pid, 0x0400 | 0x0010, h => {
        IntPtr pbi = Marshal.AllocHGlobal(48);
        try {
          int ret;
          if (NtQueryInformationProcess(h, 0, pbi, 48, out ret) != 0) return false;
          long peb = Marshal.ReadInt64(pbi, 8);
          byte[] b8 = new byte[8]; IntPtr read;
          if (!ReadProcessMemory(h, new IntPtr(peb + 0x20), b8, new IntPtr(8), out read)) return false;
          long parameters = BitConverter.ToInt64(b8, 0);
          byte[] us = new byte[16];
          if (!ReadProcessMemory(h, new IntPtr(parameters + 0x38), us, new IntPtr(16), out read)) return false;
          int len = BitConverter.ToUInt16(us, 0);
          long text = BitConverter.ToInt64(us, 8);
          if (len <= 0 || len > 4096) return false;
          byte[] s = new byte[len];
          if (!ReadProcessMemory(h, new IntPtr(text), s, new IntPtr(len), out read)) return false;
          result = Encoding.Unicode.GetString(s).TrimEnd('\\');
          if (result.Length == 2 && result[1] == ':') result += "\\";
          return true;
        } finally { Marshal.FreeHGlobal(pbi); }
      });
      return result;
    }

    // The command line the process was started with (its PEB), read from its memory.
    public static string CommandLine(int pid) {
      string result = null;
      With(pid, 0x0400 | 0x0010, h => {
        IntPtr pbi = Marshal.AllocHGlobal(48);
        try {
          int ret;
          if (NtQueryInformationProcess(h, 0, pbi, 48, out ret) != 0) return false;
          long peb = Marshal.ReadInt64(pbi, 8);
          byte[] b8 = new byte[8]; IntPtr read;
          if (!ReadProcessMemory(h, new IntPtr(peb + 0x20), b8, new IntPtr(8), out read)) return false;
          long parameters = BitConverter.ToInt64(b8, 0);
          byte[] us = new byte[16];
          if (!ReadProcessMemory(h, new IntPtr(parameters + 0x70), us, new IntPtr(16), out read)) return false;
          int len = BitConverter.ToUInt16(us, 0);
          long text = BitConverter.ToInt64(us, 8);
          if (len <= 0) return false;
          byte[] s = new byte[len];
          if (!ReadProcessMemory(h, new IntPtr(text), s, new IntPtr(len), out read)) return false;
          result = Encoding.Unicode.GetString(s);
          return true;
        } finally { Marshal.FreeHGlobal(pbi); }
      });
      return result ?? "";
    }

    static long prevIdle, prevTotal;
    public static double CpuPercent() {
      long idle, kernel, user;
      if (!GetSystemTimes(out idle, out kernel, out user)) return 0;
      long total = kernel + user;
      double pct = 0;
      if (prevTotal > 0 && total > prevTotal) pct = 100.0 * (1 - (double)(idle - prevIdle) / (total - prevTotal));
      prevIdle = idle; prevTotal = total;
      return Math.Max(0, Math.Min(100, pct));
    }

    // Total and available physical memory, in MB.
    public static double[] Memory() {
      var m = new MemStatus(); m.Length = (uint)Marshal.SizeOf(typeof(MemStatus));
      GlobalMemoryStatusEx(ref m);
      return new double[] { m.Total / 1048576.0, m.Avail / 1048576.0 };
    }

    public static string FormatMB(double mb) {
      return mb >= 1024 ? (mb / 1024).ToString("N1") + " GB" : mb.ToString("N0") + " MB";
    }

    // The programs outside Claude that hold the most memory, grouped by name.
    public static List<Other> TopOthers(List<Proc> procs, HashSet<int> exclude, int count) {
      var sums = new Dictionary<string, long>(); var counts = new Dictionary<string, int>(); var pids = new Dictionary<string, List<int>>();
      foreach (var p in procs) {
        if (exclude.Contains(p.Pid) || p.Pid == 0 || p.Name == "System" || p.Name == "Registry" || p.Name == "Memory Compression" || p.Name == "Idle") continue;
        long s; sums.TryGetValue(p.Name, out s); sums[p.Name] = s + p.WorkingSet;
        int c; counts.TryGetValue(p.Name, out c); counts[p.Name] = c + 1;
        List<int> l; if (!pids.TryGetValue(p.Name, out l)) { l = new List<int>(); pids[p.Name] = l; } l.Add(p.Pid);
      }
      var keys = new List<string>(sums.Keys);
      keys.Sort((a, b) => sums[b].CompareTo(sums[a]));
      var top = new List<Other>();
      for (int i = 0; i < keys.Count && i < count; i++) {
        string bare = keys[i].EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? keys[i].Substring(0, keys[i].Length - 4) : keys[i];
        double mb = sums[keys[i]] / 1048576.0;
        top.Add(new Other { Name = counts[keys[i]] > 1 ? bare + " ×" + counts[keys[i]] : bare, MB = mb, Mem = FormatMB(mb), Key = keys[i], Count = counts[keys[i]], Pids = pids[keys[i]].ToArray() });
      }
      return top;
    }
  }

  public static class Geo {
    // A line through the samples, newest at the right edge.
    public static PointCollection Spark(double[] values, double w, double h, int len, double max, double left) {
      var pts = new PointCollection(values.Length);
      if (w <= 0 || values.Length == 0 || len < 2) return pts;
      double step = w / (len - 1);
      int offset = len - values.Length;
      for (int i = 0; i < values.Length; i++) pts.Add(new Point(left + (offset + i) * step, h - (Math.Min(values[i], max) / max * (h - 4)) - 2));
      return pts;
    }
    // Every sample's dot as one geometry: a single shape to draw instead of fifty.
    public static Geometry Dots(PointCollection pts, double r) {
      var g = new StreamGeometry();
      using (var c = g.Open()) {
        for (int i = 0; i < pts.Count - 1; i++) {
          var p = pts[i];
          c.BeginFigure(new Point(p.X - r, p.Y), true, true);
          c.ArcTo(new Point(p.X + r, p.Y), new Size(r, r), 0, false, SweepDirection.Clockwise, true, false);
          c.ArcTo(new Point(p.X - r, p.Y), new Size(r, r), 0, false, SweepDirection.Clockwise, true, false);
        }
      }
      g.Freeze();
      return g;
    }
  }
}
'@
# Compilar el C# cuesta más que todo lo demás al abrir: se guarda compilado y se reutiliza mientras no cambie.
$binDir = Join-Path $env:USERPROFILE '.claude\task-monitor\bin'
$hash = [BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($nativeSource))).Replace('-', '').Substring(0, 12)
$dll = Join-Path $binDir "TaskMon-$hash.dll"
$refs = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -in 'PresentationCore', 'PresentationFramework', 'WindowsBase', 'System.Xaml' } | ForEach-Object Location) + @([System.Reflection.Assembly]::LoadWithPartialName('System.Web.Extensions').Location)
if (-not (Test-Path -LiteralPath $dll)) {
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  Get-ChildItem -LiteralPath $binDir -Filter 'TaskMon-*.dll' | Remove-Item -Force
  Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library
}
if (Test-Path -LiteralPath $dll) { Add-Type -LiteralPath $dll } else { Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies $refs }

$dataDir = Join-Path $env:USERPROFILE '.claude\task-monitor'
$sessionDir = Join-Path $dataDir 'sessions'
$settingsFile = Join-Path $dataDir 'settings.json'
$metaFile = Join-Path $dataDir 'meta.json'
$pausedFile = Join-Path $dataDir 'paused.json'
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
$cores = [Environment]::ProcessorCount
$historyLen = 50
$taskHistoryLen = 30
$version = '1.5'

# --- Ajustes y datos persistentes -------------------------------------------------
$defaults = [ordered]@{
  style = 'hacker'; theme = 'matrix'; openMode = 'always'; ramThreshold = 80; refreshSec = 2; reservePct = 15
  crt = $true; soundCritical = $false; soundDone = $false; topmost = $false; nefFondo = 'angel_caido'; sprites = $true; fixedSize = $false; fixedBounds = $null; groupMode = 'pinned'; sortMode = 'opened'; diaryScope = 'open'; dockTerminal = $false; stage = 'gym'; homeTab = 'tasks'; renderAutoNext = $false
}
function Read-Json($path) {
  if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
}
function To-Hashtable($obj) {
  $h = @{}
  if ($obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
  $h
}
$settings = [ordered]@{}
foreach ($k in $defaults.Keys) { $settings[$k] = $defaults[$k] }
$saved = Read-Json $settingsFile
if ($saved) { foreach ($p in $saved.PSObject.Properties) { if ($settings.Contains($p.Name)) { $settings[$p.Name] = $p.Value } } }
function Save-Settings { $settings | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8 }
Save-Settings

# meta: nombre y fijado por sesión (clave = id de sesión, y también pid:N)
$meta = @{}
foreach ($p in (Read-Json $metaFile).PSObject.Properties) { $meta[$p.Name] = To-Hashtable $p.Value }
function Save-Meta { $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metaFile -Encoding UTF8 }

# paused: pid raíz -> @{ since; pids }
$paused = @{}
foreach ($p in (Read-Json $pausedFile).PSObject.Properties) { $paused[[int]$p.Name] = To-Hashtable $p.Value }
function Save-Paused {
  $out = @{}; foreach ($k in $paused.Keys) { $out["$k"] = $paused[$k] }
  $out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pausedFile -Encoding UTF8
}

# Paletas del estilo Hacker
$themes = [ordered]@{
  matrix    = @{ Name = 'Matrix';    Accent = '#39FF88'; Accent2 = '#22D3EE'; Bg = '#05080A'; Bg2 = '#030506'; Panel = '#0A1114'; Line = '#143A2C'; Dim = '#4E7A66'; Text = '#B8F5D0'; Bright = '#E2FFEE'; Soft = '#8FC7AA'; Track = '#0F1E1A'; Deep = '#1F6B4C'; AccentSoft = '#10261D' }
  cyber     = @{ Name = 'Cyberpunk'; Accent = '#00E5FF'; Accent2 = '#FF2BD6'; Bg = '#05060B'; Bg2 = '#030409'; Panel = '#0A0D18'; Line = '#1A2448'; Dim = '#5A6A9A'; Text = '#C6D4FF'; Bright = '#EEF3FF'; Soft = '#93A4D6'; Track = '#111833'; Deep = '#2A3D7A'; AccentSoft = '#0F1A33' }
  amber     = @{ Name = 'Ámbar CRT'; Accent = '#FFB000'; Accent2 = '#FF7A1A'; Bg = '#0A0703'; Bg2 = '#060402'; Panel = '#120D06'; Line = '#3A2A10'; Dim = '#8A6A3A'; Text = '#FFD9A0'; Bright = '#FFF1DA'; Soft = '#D6AE72'; Track = '#1E160A'; Deep = '#6B4A1A'; AccentSoft = '#2A1D08' }
  synthwave = @{ Name = 'Synthwave'; Accent = '#FF4FD8'; Accent2 = '#8B5CF6'; Bg = '#0B0613'; Bg2 = '#07040D'; Panel = '#140B22'; Line = '#36204F'; Dim = '#7D64A0'; Text = '#EBD7FF'; Bright = '#FFF0FF'; Soft = '#BFA3E0'; Track = '#1D1030'; Deep = '#5B2D86'; AccentSoft = '#2A1240' }
  ice       = @{ Name = 'Hielo';     Accent = '#7DD3FC'; Accent2 = '#A5B4FC'; Bg = '#060A10'; Bg2 = '#04070B'; Panel = '#0B121C'; Line = '#1C2C42'; Dim = '#5B7390'; Text = '#D6E6F5'; Bright = '#F2F8FF'; Soft = '#9DB4CC'; Track = '#111C2A'; Deep = '#2C4B6E'; AccentSoft = '#10202F' }
}

# Estilos de apariencia: tipografía, forma, decoración de las gráficas y paleta propia
$styles = [ordered]@{
  simple   = @{ Name = 'Simple'; Detail = 'limpio y tranquilo, como la primera versión'
                Font = 'Segoe UI'; Num = 'Segoe UI Semibold'; Radius = 8; Glow = $false; Grid = $false; Axis = $false; Dots = $false; Area = $false; Delta = $false; Stats = $false; Trend = $false
                Palette = @{ Accent = '#4CC38A'; Accent2 = '#5B9DFF'; Bg = '#15171C'; Bg2 = '#101216'; Panel = '#1E2129'; Line = '#2A2E38'; Dim = '#8B91A0'; Text = '#E6E8EE'; Bright = '#FFFFFF'; Soft = '#B8BDC9'; Track = '#2A2E38'; Deep = '#3A3F4B'; AccentSoft = '#262A33' } }
  analytic = @{ Name = 'Analítica'; Detail = 'panel de datos estilo economía: ejes, rejilla y mín/media/máx'
                Font = 'Segoe UI'; Num = 'Bahnschrift'; Radius = 4; Glow = $false; Grid = $true; Axis = $true; Dots = $true; Area = $true; Delta = $false; Stats = $true; Trend = $false
                Palette = @{ Accent = '#F2B544'; Accent2 = '#4FA3FF'; Bg = '#0E1525'; Bg2 = '#0A101C'; Panel = '#131C2E'; Line = '#22304A'; Dim = '#7C8BA5'; Text = '#DCE4F2'; Bright = '#FFFFFF'; Soft = '#A9B6CC'; Track = '#1C2840'; Deep = '#2E4166'; AccentSoft = '#1A2740' } }
  trading  = @{ Name = 'Trading'; Detail = 'terminal de bolsa: variación ▲▼ (verde sube, rojo baja), rejilla y ticker'
                Font = 'Bahnschrift'; Num = 'Consolas'; Radius = 2; Glow = $false; Grid = $true; Axis = $true; Dots = $true; Area = $true; Delta = $true; Stats = $false; Trend = $true
                Palette = @{ Accent = '#0ECB81'; Accent2 = '#F0B90B'; Bg = '#0B0E11'; Bg2 = '#07090B'; Panel = '#161A1E'; Line = '#2B3139'; Dim = '#848E9C'; Text = '#EAECEF'; Bright = '#FFFFFF'; Soft = '#B7BDC6'; Track = '#1E2329'; Deep = '#2B3139'; AccentSoft = '#1E2329' } }
  nefralis = @{ Name = 'Nefralis'; Detail = 'como la app Nefralis: estatuas de fondo, tarjetas oscuras, subtítulos con barrita y un único acento azul'
                Font = 'Segoe UI'; Num = 'Segoe UI Semibold'; Radius = 12; Glow = $false; Grid = $false; Axis = $false; Dots = $false; Area = $true; Delta = $false; Stats = $false; Trend = $false
                Palette = @{ Accent = '#4AA6C4'; Accent2 = '#57AECB'; Bg = '#0E0F11'; Bg2 = '#1E2329'; Panel = '#1C1E22'; Line = '#3A3D42'; Dim = '#9A9FA6'; Text = '#E7E8EA'; Bright = '#F4F5F6'; Soft = '#BCC0C6'; Track = '#26282C'; Deep = '#6C7075'; AccentSoft = '#16303A' } }
  hacker   = @{ Name = 'Hacker'; Detail = 'terminal con brillo neón y efecto CRT; elige paleta abajo'
                Font = 'Cascadia Mono, Consolas'; Num = 'Cascadia Mono, Consolas'; Radius = 0; Glow = $true; Grid = $false; Axis = $false; Dots = $true; Area = $true; Delta = $false; Stats = $false; Trend = $false
                Palette = $null }
}
$up = '#0ECB81'; $down = '#F6465D'
# Porcentajes (CPU, RAM, uso de Claude...): verde por debajo de 70, amarillo de 70 a 90, rojo desde 90
$ok = '#22C55E'; $warn = '#FACC15'; $crit = '#EF4444'; $resumeColor = '#A78BFA'
function Level([double]$pct) { if ($pct -ge 90) { 2 } elseif ($pct -ge 70) { 1 } else { 0 } }
function Level-Color([double]$pct) { @($ok, $warn, $crit)[(Level $pct)] }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Task Monitor" Width="560" Height="820" MinWidth="460" MinHeight="520"
        Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}" FontSize="12"
        WindowStyle="None" ResizeMode="CanResize" ShowActivated="False" WindowStartupLocation="Manual"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="36" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0"/>
  </WindowChrome.WindowChrome>
  <Window.Icon>
    <DrawingImage>
      <DrawingImage.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="#05080A">
            <GeometryDrawing.Pen><Pen Brush="#39FF88" Thickness="2"/></GeometryDrawing.Pen>
            <GeometryDrawing.Geometry><RectangleGeometry Rect="1,1,30,30" RadiusX="6" RadiusY="6"/></GeometryDrawing.Geometry>
          </GeometryDrawing>
          <GeometryDrawing>
            <GeometryDrawing.Pen><Pen Brush="#39FF88" Thickness="3.2" StartLineCap="Round" EndLineCap="Round" LineJoin="Round"/></GeometryDrawing.Pen>
            <GeometryDrawing.Geometry><PathGeometry Figures="M8,10 L14,16 L8,22 M17,22 L24,22"/></GeometryDrawing.Geometry>
          </GeometryDrawing>
        </DrawingGroup>
      </DrawingImage.Drawing>
    </DrawingImage>
  </Window.Icon>

  <Window.Resources>
    <Style TargetType="TextBlock" x:Key="Tag">
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Muted">
      <Setter Property="Foreground" Value="{DynamicResource Dim}"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Section">
      <Setter Property="Foreground" Value="{DynamicResource Accent2}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,18,0,8"/>
    </Style>

    <Style TargetType="Button" x:Key="ChromeBtn">
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Foreground" Value="{DynamicResource Dim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" MinWidth="42" Height="36" Padding="10,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
                <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button" x:Key="CloseBtn" BasedOn="{StaticResource ChromeBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" Width="46" Height="36">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#C42B45"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ToggleButton" x:Key="ChromeToggle">
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Foreground" Value="{DynamicResource Dim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Bd" Background="Transparent" Padding="12,0" Height="36">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource Bg}"/>
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button" x:Key="TermBtn">
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
      <Setter Property="FontFamily" Value="{DynamicResource UiFont}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" BorderBrush="{TemplateBinding Foreground}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Padding="14,6" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="RadioButton" x:Key="TermRadio">
      <Setter Property="Foreground" Value="{DynamicResource Soft}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,16,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" Padding="2,2">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="Mark" Text="○ " Foreground="{DynamicResource Dim}"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Mark" Property="Text" Value="● "/>
                <Setter TargetName="Mark" Property="Foreground" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource Bright}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox" x:Key="TermCheck">
      <Setter Property="Foreground" Value="{DynamicResource Soft}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Bd" Background="Transparent" Padding="2,2">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="Mark" Text="☐ " Foreground="{DynamicResource Dim}"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Mark" Property="Text" Value="☑ "/>
                <Setter TargetName="Mark" Property="Foreground" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource Bright}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ContextMenu" x:Key="TermMenu">
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Deep}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Padding="0,4" MinWidth="280">
              <StackPanel IsItemsHost="True"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="MenuItem" x:Key="TermMenuItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="Bd" Padding="14,6" Background="Transparent">
              <ContentPresenter ContentSource="Header" RecognizesAccessKey="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
                <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Expander" x:Key="DiaryExp">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <DockPanel>
              <ToggleButton DockPanel.Dock="Top" Cursor="Hand" Content="{TemplateBinding Header}"
                            IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="Transparent" CornerRadius="{DynamicResource Radius}">
                      <DockPanel>
                        <TextBlock x:Name="Chev" DockPanel.Dock="Right" Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="{DynamicResource Dim}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                        <ContentPresenter/>
                      </DockPanel>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="Chev" Property="Text" Value="&#xE70E;"/></Trigger>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="Body" Visibility="Collapsed"/>
            </DockPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="Body" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Border" x:Key="Plate">
      <Setter Property="Background" Value="{DynamicResource Plate}"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="{DynamicResource PlatePad}"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Border" x:Key="PlateBar">
      <Setter Property="Width" Value="3"/>
      <Setter Property="Height" Value="12"/>
      <Setter Property="CornerRadius" Value="2"/>
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
      <Setter Property="Visibility" Value="{DynamicResource PlateBarVis}"/>
    </Style>
    <Style TargetType="MenuItem" x:Key="TermMenuStatic">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem"><ContentPresenter ContentSource="Header" RecognizesAccessKey="False"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{DynamicResource Panel}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Deep}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Padding" Value="10,7"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="5"/>
      <Setter Property="MinWidth" Value="5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource Deep}" CornerRadius="2"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="TaskCard">
                <Border x:Name="Card" Background="{Binding [CardBg]}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Margin="{DynamicResource CardGap}" ToolTip="{Binding [Tip]}" Cursor="Hand">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="3"/><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <Border Background="{Binding [StateColor]}" CornerRadius="2,0,0,2"/>
                    <Border x:Name="SpriteBox" Grid.Column="1" Visibility="{DynamicResource SpriteVis}" BorderBrush="{Binding [StateColor]}" BorderThickness="1.5" CornerRadius="5" Margin="8,0,0,0"
                            Width="63" Height="47" VerticalAlignment="Center" ToolTip="{Binding [SceneTip]}">
                      <Image x:Name="Sprite" Width="60" Height="44" Stretch="Fill" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
                    </Border>
                    <StackPanel Grid.Column="2" Margin="10,6,10,6" VerticalAlignment="Center">
                      <DockPanel>
                        <Border DockPanel.Dock="Right" Background="{Binding [StateColor]}" CornerRadius="{DynamicResource Radius}" Padding="7,1" VerticalAlignment="Center" Margin="8,0,0,0">
                          <StackPanel Orientation="Horizontal">
                            <Ellipse x:Name="Dot" Width="6" Height="6" Fill="#E60E0F11" VerticalAlignment="Center" Margin="0,0,5,0"/>
                            <TextBlock Text="{Binding [StateLabel]}" Foreground="#0E0F11" FontWeight="Bold" FontSize="10"/>
                          </StackPanel>
                        </Border>
                        <TextBlock DockPanel.Dock="Left" Text="{Binding [PinMark]}" Foreground="{DynamicResource Accent}" Margin="0,0,5,0" VerticalAlignment="Center"/>
                        <Grid>
                          <TextBlock x:Name="TitleText" Text="{Binding [Title]}" Visibility="{Binding [TitleVis]}" FontSize="14" FontWeight="Bold" Foreground="{DynamicResource Bright}"
                                     TextTrimming="CharacterEllipsis" Cursor="IBeam"/>
                          <TextBox x:Name="TitleBox" Visibility="{Binding [EditVis]}" FontSize="13" FontWeight="Bold"
                                   Background="{DynamicResource Bg}" Foreground="{DynamicResource Bright}" BorderBrush="{DynamicResource Accent}" BorderThickness="1"
                                   CaretBrush="{DynamicResource Accent}" SelectionBrush="{DynamicResource Deep}" Padding="3,0" FontFamily="{DynamicResource UiFont}"/>
                        </Grid>
                      </DockPanel>
                      <DockPanel Margin="0,3,0,0">
                        <Canvas DockPanel.Dock="Right" Width="84" Height="14" ClipToBounds="True" Margin="8,0,0,0" VerticalAlignment="Center">
                          <Polyline Points="{Binding [Spark]}" Stroke="{Binding [StateColor]}" StrokeThickness="1.2"/>
                        </Canvas>
                        <TextBlock Text="{Binding [Info]}" Style="{StaticResource Muted}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" FontFamily="{DynamicResource NumFont}"/>
                      </DockPanel>
                      <TextBlock Text="{Binding [Prompt]}" Foreground="{DynamicResource Soft}" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,2,0,0" Opacity="0.8"/>
                    </StackPanel>
                  </Grid>
                </Border>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding [Blink]}" Value="1">
                    <Setter TargetName="Dot" Property="Opacity" Value="{Binding Tag, RelativeSource={RelativeSource AncestorType=Window}}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding [State]}" Value="waiting">
                    <Setter TargetName="Card" Property="BorderBrush" Value="{Binding [StateColor]}"/>
                    <Setter TargetName="SpriteBox" Property="Opacity" Value="{Binding Tag, RelativeSource={RelativeSource AncestorType=Window}}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding [State]}" Value="error">
                    <Setter TargetName="Card" Property="BorderBrush" Value="{Binding [StateColor]}"/>
                  </DataTrigger>
                  <Trigger SourceName="Card" Property="IsMouseOver" Value="True">
                    <Setter TargetName="Card" Property="BorderBrush" Value="{DynamicResource Deep}"/>
                  </Trigger>
                </DataTemplate.Triggers>
              </DataTemplate>

    <!-- Navegación de la pestaña de inicio: Claude Tasks / Render -->
    <Style TargetType="RadioButton" x:Key="NavTab">
      <Setter Property="Foreground" Value="{DynamicResource Dim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="0,0,0,2" Padding="12,5,12,5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource Bright}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Tarjeta de un render (compacta, como las de Claude Tasks): portada del canal, título del mp4, dos barras en una fila y una línea de estado -->
    <DataTemplate x:Key="RenderCard">
                <Border x:Name="Card" Background="{Binding [CardBg]}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Margin="{DynamicResource CardGap}" ToolTip="{Binding [Tip]}" Cursor="Hand">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="3"/><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <Border Background="{Binding [StateColor]}" CornerRadius="2,0,0,2"/>
                    <Grid Grid.Column="1" Width="47" Height="47" Margin="8,0,0,0" VerticalAlignment="Center">
                      <Border CornerRadius="5" BorderBrush="{Binding [StateColor]}" BorderThickness="1.5" Background="{DynamicResource SpriteBg}">
                        <Image Source="{Binding [Cover]}" Stretch="UniformToFill" Width="44" Height="44" RenderOptions.BitmapScalingMode="HighQuality">
                          <Image.Clip><RectangleGeometry Rect="0,0,44,44" RadiusX="4" RadiusY="4"/></Image.Clip>
                        </Image>
                      </Border>
                      <TextBlock Text="{Binding [Glyph]}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="18" Foreground="{Binding [StateColor]}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="{Binding [GlyphVis]}"/>
                      <Border CornerRadius="5" Background="#99000000" Visibility="{Binding [OverlayVis]}">
                        <TextBlock Text="{Binding [Overlay]}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" Foreground="{Binding [StateColor]}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                    </Grid>
                    <StackPanel Grid.Column="2" Margin="10,6,10,6" VerticalAlignment="Center">
                      <DockPanel>
                        <Border DockPanel.Dock="Right" Background="{Binding [StateColor]}" CornerRadius="{DynamicResource Radius}" Padding="7,1" VerticalAlignment="Center" Margin="8,0,0,0">
                          <StackPanel Orientation="Horizontal">
                            <Ellipse x:Name="Dot" Width="6" Height="6" Fill="#E60E0F11" VerticalAlignment="Center" Margin="0,0,5,0"/>
                            <TextBlock Text="{Binding [StateLabel]}" Foreground="#0E0F11" FontWeight="Bold" FontSize="10"/>
                          </StackPanel>
                        </Border>
                        <TextBlock Text="{Binding [Title]}" FontSize="14" FontWeight="Bold" Foreground="{DynamicResource Bright}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                      </DockPanel>
                      <Grid Margin="0,4,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="62"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                        <TextBlock Text="{Binding [Bar1Label]}" Foreground="{DynamicResource Dim}" FontSize="10" VerticalAlignment="Center"/>
                        <Grid Grid.Column="1" Height="5" VerticalAlignment="Center">
                          <Border Background="{DynamicResource Track}" CornerRadius="2.5"/>
                          <Border Background="{Binding [StateColor]}" CornerRadius="2.5" RenderTransformOrigin="0,0.5">
                            <Border.RenderTransform><ScaleTransform ScaleX="{Binding [RFrac]}"/></Border.RenderTransform>
                          </Border>
                        </Grid>
                        <TextBlock Grid.Column="2" Text="{Binding [RText]}" Foreground="{DynamicResource Soft}" FontSize="10" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" MinWidth="70" TextAlignment="Right" Margin="8,0,0,0"/>
                        <TextBlock Grid.Row="1" Text="{Binding [Bar2Label]}" Foreground="{DynamicResource Dim}" FontSize="10" VerticalAlignment="Center" Margin="0,2,0,0"/>
                        <Grid Grid.Row="1" Grid.Column="1" Height="5" VerticalAlignment="Center" Margin="0,2,0,0">
                          <Border Background="{DynamicResource Track}" CornerRadius="2.5"/>
                          <Border Background="{Binding [Bar2Color]}" CornerRadius="2.5" RenderTransformOrigin="0,0.5">
                            <Border.RenderTransform><ScaleTransform ScaleX="{Binding [EFrac]}"/></Border.RenderTransform>
                          </Border>
                        </Grid>
                        <TextBlock Grid.Row="1" Grid.Column="2" Text="{Binding [EText]}" Foreground="{DynamicResource Soft}" FontSize="10" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" MinWidth="70" TextAlignment="Right" Margin="8,2,0,0"/>
                      </Grid>
                      <TextBlock Text="{Binding [Eta]}" Foreground="{Binding [EtaColor]}" FontSize="11" TextTrimming="CharacterEllipsis" Margin="0,3,0,0" Opacity="0.9"/>
                    </StackPanel>
                  </Grid>
                </Border>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding [Blink]}" Value="1">
                    <Setter TargetName="Dot" Property="Opacity" Value="{Binding Tag, RelativeSource={RelativeSource AncestorType=Window}}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding [State]}" Value="error">
                    <Setter TargetName="Card" Property="BorderBrush" Value="{Binding [StateColor]}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding [State]}" Value="paused">
                    <Setter TargetName="Card" Property="BorderBrush" Value="{Binding [StateColor]}"/>
                  </DataTrigger>
                  <Trigger SourceName="Card" Property="IsMouseOver" Value="True">
                    <Setter TargetName="Card" Property="BorderBrush" Value="{DynamicResource Deep}"/>
                  </Trigger>
                </DataTemplate.Triggers>
              </DataTemplate>
  </Window.Resources>

  <Border x:Name="Frame" BorderThickness="1" BorderBrush="{DynamicResource Line}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="36"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="104"/>
        <RowDefinition Height="24"/>
      </Grid.RowDefinitions>

      <!-- Fondo ilustrado (estilo Nefralis) -->
      <Rectangle x:Name="BgImage" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed"/>
      <Rectangle x:Name="BgVeil" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed">
        <Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#1F000000" Offset="0"/><GradientStop Color="#14000000" Offset="0.4"/><GradientStop Color="#80000000" Offset="1"/>
          </LinearGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="BgGlow" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed" IsHitTestVisible="False">
        <Rectangle.Fill>
          <RadialGradientBrush Center="0.5,0" GradientOrigin="0.5,0" RadiusX="0.8" RadiusY="0.45">
            <GradientStop Color="#334AA6C4" Offset="0"/><GradientStop Color="#004AA6C4" Offset="1"/>
          </RadialGradientBrush>
        </Rectangle.Fill>
      </Rectangle>

      <!-- Barra de título -->
      <Rectangle x:Name="AccentLine" Grid.Row="0" Height="1" VerticalAlignment="Bottom" Panel.ZIndex="1" Visibility="Collapsed" IsHitTestVisible="False">
        <Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#004AA6C4" Offset="0"/><GradientStop Color="#804AA6C4" Offset="0.5"/><GradientStop Color="#004AA6C4" Offset="1"/>
          </LinearGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
      <Border Grid.Row="0" Background="{DynamicResource Bg2}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <ToggleButton x:Name="StageBtn" Style="{StaticResource ChromeToggle}" ToolTip="Escenario: un Claude por sesión, haciendo algo según su estado">
              <TextBlock Text="&#xE7FC;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14"/>
            </ToggleButton>
            <ToggleButton x:Name="DiaryBtn" Style="{StaticResource ChromeToggle}" ToolTip="Diario: lo que ha hecho cada sesión">
              <TextBlock Text="&#xE82D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14"/>
            </ToggleButton>
            <ToggleButton x:Name="SettingsBtn" Style="{StaticResource ChromeToggle}" ToolTip="Ajustes">
              <TextBlock Text="&#xE713;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14"/>
            </ToggleButton>
            <Button x:Name="MinBtn" Style="{StaticResource ChromeBtn}" ToolTip="Minimizar">
              <Rectangle Width="10" Height="1.5" Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
            </Button>
            <Button x:Name="CloseBtn" Style="{StaticResource CloseBtn}" ToolTip="Cerrar">
              <Path Data="M0,0 L10,10 M10,0 L0,10" StrokeThickness="1.5" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
            </Button>
          </StackPanel>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
            <Image x:Name="TitleIcon" Source="{Binding Icon, RelativeSource={RelativeSource AncestorType=Window}}" Width="16" Height="16" Margin="0,0,10,0"/>
            <Ellipse x:Name="NefIcon" Width="22" Height="22" Margin="0,0,10,0" Visibility="Collapsed" Stroke="{DynamicResource Accent}" StrokeThickness="1"/>
            <StackPanel x:Name="HackerTitle" Orientation="Horizontal">
              <TextBlock Text="claude" Foreground="{DynamicResource Accent}" FontWeight="Bold"/>
              <TextBlock Text="@" Foreground="{DynamicResource Dim}"/>
              <TextBlock Text="task-monitor" Foreground="{DynamicResource Accent2}" FontWeight="Bold"/>
              <TextBlock Text=":~$ " Foreground="{DynamicResource Dim}"/>
              <TextBlock x:Name="TitleCmd" Text="watch" Foreground="{DynamicResource Text}"/>
              <TextBlock x:Name="Cursor" Text="█" Foreground="{DynamicResource Accent}" Margin="2,0,0,0" Opacity="{Binding Tag, RelativeSource={RelativeSource AncestorType=Window}}"/>
            </StackPanel>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="PlainTitle" Foreground="{DynamicResource Bright}" FontWeight="SemiBold" FontSize="13" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="TitleSub" Foreground="{DynamicResource Soft}" FontSize="9.5" Margin="0,-1,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <TextBlock x:Name="Ticker" Foreground="{DynamicResource Soft}" FontSize="11" Margin="14,0,0,0" VerticalAlignment="Center" FontFamily="{DynamicResource NumFont}"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- Cabecera fija: CPU y RAM -->
      <Border Grid.Row="1" Background="{DynamicResource HeaderBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1" Padding="10,8,10,8">
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Padding="10,6,10,6">
              <StackPanel>
                <DockPanel>
                  <Image x:Name="CpuMark" Width="18" Height="18" Margin="0,0,6,0" VerticalAlignment="Center" Opacity="0.9" Visibility="Collapsed"/>
                  <TextBlock x:Name="CpuTag" Style="{StaticResource Tag}" FontSize="10" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <TextBlock x:Name="CpuText" Text="--" FontSize="24" FontWeight="Bold" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center">
                    <TextBlock.Effect><DropShadowEffect x:Name="CpuGlow" ShadowDepth="0" BlurRadius="14" Opacity="0"/></TextBlock.Effect>
                  </TextBlock>
                  <TextBlock x:Name="CpuDelta" FontSize="11" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </DockPanel>
                <Canvas x:Name="CpuCanvas" Height="40" ClipToBounds="True" Margin="0,4,0,0">
                  <Polygon x:Name="CpuArea"/>
                  <Polyline x:Name="CpuLine" StrokeThickness="1.4" StrokeLineJoin="Round"/>
                  <Path x:Name="CpuDots"/>
                  <Ellipse x:Name="CpuHead" Width="6" Height="6" Visibility="Collapsed"/>
                </Canvas>
                <DockPanel Margin="0,3,0,0">
                  <TextBlock x:Name="CpuSide" DockPanel.Dock="Right" Style="{StaticResource Muted}" FontSize="10" Margin="8,0,0,0"/>
                  <TextBlock x:Name="CpuStats" Style="{StaticResource Muted}" FontSize="10" FontFamily="{DynamicResource NumFont}" TextTrimming="CharacterEllipsis"/>
                </DockPanel>
              </StackPanel>
            </Border>
            <Border Grid.Column="2" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Padding="10,6,10,6">
              <StackPanel>
                <DockPanel>
                  <Image x:Name="RamMark" Width="18" Height="18" Margin="0,0,6,0" VerticalAlignment="Center" Opacity="0.9" Visibility="Collapsed"/>
                  <TextBlock x:Name="RamTag" Style="{StaticResource Tag}" FontSize="10" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <TextBlock x:Name="RamText" Text="--" FontSize="24" FontWeight="Bold" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center">
                    <TextBlock.Effect><DropShadowEffect x:Name="RamGlow" ShadowDepth="0" BlurRadius="14" Opacity="0"/></TextBlock.Effect>
                  </TextBlock>
                  <TextBlock x:Name="RamDelta" FontSize="11" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </DockPanel>
                <Canvas x:Name="RamCanvas" Height="40" ClipToBounds="True" Margin="0,4,0,0">
                  <Polygon x:Name="RamArea"/>
                  <Polyline x:Name="RamLine" StrokeThickness="1.4" StrokeLineJoin="Round"/>
                  <Path x:Name="RamDots"/>
                  <Ellipse x:Name="RamHead" Width="6" Height="6" Visibility="Collapsed"/>
                </Canvas>
                <DockPanel Margin="0,3,0,0">
                  <TextBlock x:Name="RamSide" DockPanel.Dock="Right" Style="{StaticResource Muted}" FontSize="10" Margin="8,0,0,0"/>
                  <TextBlock x:Name="RamStats" Style="{StaticResource Muted}" FontSize="10" FontFamily="{DynamicResource NumFont}" TextTrimming="CharacterEllipsis"/>
                </DockPanel>
              </StackPanel>
            </Border>
          </Grid>
          <DockPanel Margin="0,7,0,0">
            <TextBlock x:Name="SlotsText" DockPanel.Dock="Right" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center"/>
            <TextBlock x:Name="SlotsTag" Text="SLOTS " Style="{StaticResource Tag}" FontSize="10" VerticalAlignment="Center"/>
            <WrapPanel x:Name="Slots" VerticalAlignment="Center"/>
          </DockPanel>
          <!-- Navegación: sesiones de Claude o renders de vídeo -->
          <Border BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1" Margin="-10,8,-10,-8" Padding="6,0,6,0">
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="NavTasks" GroupName="HomeNav" Style="{StaticResource NavTab}" IsChecked="True">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE99A;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontWeight="Normal" FontSize="12" VerticalAlignment="Center" Margin="0,0,7,0"/>
                  <TextBlock x:Name="NavTasksText" Text="Claude Tasks" VerticalAlignment="Center"/>
                  <Border x:Name="NavTasksBadge" Background="{DynamicResource Track}" CornerRadius="7" Padding="6,0" Margin="7,0,0,0" VerticalAlignment="Center">
                    <TextBlock x:Name="NavTasksCount" Text="0" FontSize="10" Foreground="{DynamicResource Soft}" FontFamily="{DynamicResource NumFont}"/>
                  </Border>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavRender" GroupName="HomeNav" Style="{StaticResource NavTab}">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE714;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontWeight="Normal" FontSize="12" VerticalAlignment="Center" Margin="0,0,7,0"/>
                  <TextBlock x:Name="NavRenderText" Text="Render" VerticalAlignment="Center"/>
                  <Border x:Name="NavRenderBadge" Background="{DynamicResource Track}" CornerRadius="7" Padding="6,0" Margin="7,0,0,0" VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal">
                      <Ellipse x:Name="NavRenderDot" Width="6" Height="6" Fill="#4D9BFF" VerticalAlignment="Center" Margin="0,0,4,0" Visibility="Collapsed" Opacity="{Binding Tag, RelativeSource={RelativeSource AncestorType=Window}}"/>
                      <TextBlock x:Name="NavRenderCount" Text="0" FontSize="10" Foreground="{DynamicResource Soft}" FontFamily="{DynamicResource NumFont}"/>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </RadioButton>
            </StackPanel>
          </Border>
        </StackPanel>
      </Border>

      <!-- Contenido con scroll -->
      <ScrollViewer x:Name="MainScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="10,8,6,6">
        <StackPanel Margin="0,0,4,0">
          <Border x:Name="AdviceCard" Background="{DynamicResource Panel}" BorderThickness="3,1,1,1" CornerRadius="{DynamicResource Radius}" Padding="10,7" Margin="0,0,0,10">
            <DockPanel>
            <Border x:Name="AdviceMedal" DockPanel.Dock="Left" Width="40" Height="40" CornerRadius="20" Background="#000000" BorderThickness="1.5" Margin="0,0,11,0" VerticalAlignment="Center" Visibility="Collapsed">
              <Image x:Name="AdviceIcon" Margin="6"/>
            </Border>
            <StackPanel>
              <DockPanel>
                <TextBlock x:Name="AdviceTag" DockPanel.Dock="Right" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center"/>
                <TextBlock x:Name="AdviceTitle" FontSize="13" FontWeight="Bold" TextWrapping="Wrap"/>
              </DockPanel>
              <TextBlock x:Name="AdviceBody" Foreground="{DynamicResource Soft}" FontSize="11" TextWrapping="Wrap" Margin="0,3,0,0"/>
            </StackPanel>
            </DockPanel>
          </Border>

          <DockPanel Margin="0,0,0,6">
            <Border DockPanel.Dock="Right" Style="{StaticResource Plate}"><TextBlock x:Name="TasksSummary" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center"/></Border>
            <Border Style="{StaticResource Plate}"><StackPanel Orientation="Horizontal"><Border Style="{StaticResource PlateBar}"/><TextBlock x:Name="TasksTag" Style="{StaticResource Tag}" VerticalAlignment="Center"/></StackPanel></Border>
          </DockPanel>
          <StackPanel x:Name="TaskGroups"/>
          <StackPanel x:Name="NoTasks" Orientation="Horizontal" Visibility="Collapsed" Margin="0,0,0,8">
            <Border x:Name="NoTasksMedal" Width="44" Height="44" CornerRadius="22" Background="#000000" BorderBrush="{DynamicResource Accent}" BorderThickness="1" Margin="0,0,10,0" Visibility="Collapsed">
              <Image x:Name="NoTasksIcon" Margin="6"/>
            </Border>
            <Border Style="{StaticResource Plate}"><TextBlock Style="{StaticResource Muted}" Text="No hay sesiones de Claude Code abiertas." VerticalAlignment="Center"/></Border>
          </StackPanel>
          <Border Style="{StaticResource Plate}" Margin="0,2,0,0"><TextBlock Style="{StaticResource Muted}" FontSize="10" TextWrapping="Wrap"
                     Text="Clic en una sesión: te lleva a su terminal. Clic derecho: su estado, su carpeta y acciones (renombrar, pausar, abrir carpeta…). Doble clic en el nombre para renombrar."/></Border>

          <Border Style="{StaticResource Plate}" Margin="0,12,0,6"><StackPanel Orientation="Horizontal"><Border Style="{StaticResource PlateBar}"/><TextBlock x:Name="OthersTag" Style="{StaticResource Tag}" VerticalAlignment="Center"/></StackPanel></Border>
          <Border Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Padding="10,6">
            <ItemsControl x:Name="Others">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border x:Name="Row" Background="Transparent" CornerRadius="4" Padding="4,2" Margin="-4,0" Cursor="Hand" ToolTip="{Binding Tip}">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Mark}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="{DynamicResource Dim}" VerticalAlignment="Center" Width="16"/>
                      <TextBlock Grid.Column="1" Text="{Binding Name}" Foreground="{DynamicResource Soft}" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                      <TextBlock Grid.Column="2" Text="{Binding Cpu}" FontSize="10.5" Foreground="{DynamicResource Dim}" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" Margin="10,0,12,0"/>
                      <TextBlock Grid.Column="3" Text="{Binding Mem}" FontSize="11" Foreground="{DynamicResource Bright}" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" MinWidth="56" TextAlignment="Right"/>
                    </Grid>
                  </Border>
                  <DataTemplate.Triggers>
                    <Trigger SourceName="Row" Property="IsMouseOver" Value="True">
                      <Setter TargetName="Row" Property="Background" Value="{DynamicResource AccentSoft}"/>
                    </Trigger>
                  </DataTemplate.Triggers>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Pestaña Render: lo que se está renderizando (Remotion, Blender, ffmpeg y otros programas), lo que espera y lo terminado -->
      <ScrollViewer x:Name="RenderScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="10,8,6,6" Visibility="Collapsed">
        <StackPanel Margin="0,0,4,0">
          <DockPanel Margin="0,0,0,6">
            <Border DockPanel.Dock="Right" Style="{StaticResource Plate}"><TextBlock x:Name="RenderSummary" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center"/></Border>
            <Border Style="{StaticResource Plate}"><StackPanel Orientation="Horizontal"><Border Style="{StaticResource PlateBar}"/><TextBlock x:Name="RenderTag" Style="{StaticResource Tag}" VerticalAlignment="Center"/></StackPanel></Border>
          </DockPanel>
          <ItemsControl x:Name="RenderActive" ItemTemplate="{StaticResource RenderCard}"/>
          <StackPanel x:Name="NoRenders" Orientation="Horizontal" Visibility="Collapsed" Margin="0,0,0,8">
            <Border Width="44" Height="44" CornerRadius="22" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" Margin="0,0,10,0">
              <TextBlock Text="&#xE714;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="18" Foreground="{DynamicResource Dim}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <Border Style="{StaticResource Plate}"><TextBlock Style="{StaticResource Muted}" Text="No hay ningún vídeo renderizándose ahora mismo." VerticalAlignment="Center"/></Border>
          </StackPanel>
          <DockPanel x:Name="RenderWaitHead" Margin="0,10,0,6">
            <Border DockPanel.Dock="Right" Style="{StaticResource Plate}"><TextBlock x:Name="RenderWaitSummary" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center"/></Border>
            <Border Style="{StaticResource Plate}"><StackPanel Orientation="Horizontal"><Border Style="{StaticResource PlateBar}"/><TextBlock x:Name="RenderWaitTag" Style="{StaticResource Tag}" VerticalAlignment="Center"/></StackPanel></Border>
          </DockPanel>
          <ItemsControl x:Name="RenderWait" ItemTemplate="{StaticResource RenderCard}"/>
          <DockPanel x:Name="RenderPausedHead" Margin="0,10,0,6">
            <Border DockPanel.Dock="Right" Style="{StaticResource Plate}"><TextBlock x:Name="RenderPausedSummary" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center" Text="no salen solos: clic derecho → Reanudar"/></Border>
            <Border Style="{StaticResource Plate}"><StackPanel Orientation="Horizontal"><Border Style="{StaticResource PlateBar}"/><TextBlock x:Name="RenderPausedTag" Style="{StaticResource Tag}" VerticalAlignment="Center"/></StackPanel></Border>
          </DockPanel>
          <ItemsControl x:Name="RenderPaused" ItemTemplate="{StaticResource RenderCard}"/>
          <Border x:Name="RenderDoneHead" Style="{StaticResource Plate}" Margin="0,10,0,6"><StackPanel Orientation="Horizontal"><Border Style="{StaticResource PlateBar}"/><TextBlock x:Name="RenderDoneTag" Style="{StaticResource Tag}" VerticalAlignment="Center"/></StackPanel></Border>
          <ItemsControl x:Name="RenderDone" ItemTemplate="{StaticResource RenderCard}"/>
          <Border Style="{StaticResource Plate}" Margin="0,12,0,6"><StackPanel Orientation="Horizontal"><Border Style="{StaticResource PlateBar}"/><TextBlock x:Name="RenderOthersTag" Style="{StaticResource Tag}" VerticalAlignment="Center"/></StackPanel></Border>
          <Border Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Padding="10,6" Margin="0,0,0,8">
            <ItemsControl x:Name="Others2">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border x:Name="Row" Background="Transparent" CornerRadius="4" Padding="4,2" Margin="-4,0" Cursor="Hand" ToolTip="{Binding Tip}">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Mark}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="{DynamicResource Dim}" VerticalAlignment="Center" Width="16"/>
                      <TextBlock Grid.Column="1" Text="{Binding Name}" Foreground="{DynamicResource Soft}" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                      <TextBlock Grid.Column="2" Text="{Binding Cpu}" FontSize="10.5" Foreground="{DynamicResource Dim}" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" Margin="10,0,12,0"/>
                      <TextBlock Grid.Column="3" Text="{Binding Mem}" FontSize="11" Foreground="{DynamicResource Bright}" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" MinWidth="56" TextAlignment="Right"/>
                    </Grid>
                  </Border>
                  <DataTemplate.Triggers>
                    <Trigger SourceName="Row" Property="IsMouseOver" Value="True">
                      <Setter TargetName="Row" Property="Background" Value="{DynamicResource AccentSoft}"/>
                    </Trigger>
                  </DataTemplate.Triggers>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </Border>
          <Border Style="{StaticResource Plate}" Margin="0,4,0,0"><TextBlock Style="{StaticResource Muted}" FontSize="10" TextWrapping="Wrap"
                     Text="Salen los renders con progreso (Remotion), Blender en segundo plano, ffmpeg, HandBrake y Media Encoder, los Blender que esperan turno y la cola de vídeos de FORJA. Clic derecho: pausar, reanudar, abrir su carpeta, portada, cancelar… Doble clic: abre su carpeta."/></Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Consola de eventos -->
      <Border Grid.Row="3" Background="{DynamicResource Bg2}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0">
        <DockPanel>
          <TextBlock x:Name="LogTag" DockPanel.Dock="Top" Style="{StaticResource Tag}" FontSize="10" Margin="10,5,0,2"/>
          <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" Padding="10,0,6,4">
            <ItemsControl x:Name="Log">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <TextBlock TextWrapping="Wrap" FontSize="11" Margin="0,1">
                    <Run Text="{Binding Time, Mode=OneWay}" Foreground="{DynamicResource Dim}"/>
                    <Run Text="{Binding Text, Mode=OneWay}" Foreground="{Binding Color, Mode=OneWay}"/>
                  </TextBlock>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <!-- Barra de estado -->
      <Border x:Name="StatusBar" Grid.Row="4" Background="{DynamicResource Bg2}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0">
        <DockPanel>
          <Border x:Name="StatusPill" DockPanel.Dock="Left" Background="{DynamicResource Accent}" Padding="8,0">
            <TextBlock x:Name="StatusLeft" Foreground="{DynamicResource Bg}" FontSize="10" FontWeight="Bold" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="StatusRight" DockPanel.Dock="Right" Foreground="{DynamicResource Dim}" FontSize="10" VerticalAlignment="Center" Margin="10,0,8,0" FontFamily="{DynamicResource NumFont}"/>
          <StackPanel x:Name="UsagePanel" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Right" Background="Transparent">
            <TextBlock Text="Semana" Foreground="{DynamicResource Soft}" FontSize="10" VerticalAlignment="Center" Margin="0,0,5,0"/>
            <Grid Width="44" Height="5" VerticalAlignment="Center">
              <Border Background="{DynamicResource Track}" CornerRadius="2"/>
              <Border x:Name="WeekBar" CornerRadius="2" RenderTransformOrigin="0,0.5"><Border.RenderTransform><ScaleTransform x:Name="WeekScale" ScaleX="0"/></Border.RenderTransform></Border>
            </Grid>
            <TextBlock x:Name="WeekText" Text="--" FontSize="10" FontWeight="Bold" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" Margin="5,0,12,0"/>
            <TextBlock Text="5 h" Foreground="{DynamicResource Soft}" FontSize="10" VerticalAlignment="Center" Margin="0,0,5,0"/>
            <Grid Width="44" Height="5" VerticalAlignment="Center">
              <Border Background="{DynamicResource Track}" CornerRadius="2"/>
              <Border x:Name="FiveBar" CornerRadius="2" RenderTransformOrigin="0,0.5"><Border.RenderTransform><ScaleTransform x:Name="FiveScale" ScaleX="0"/></Border.RenderTransform></Border>
            </Grid>
            <TextBlock x:Name="FiveText" Text="--" FontSize="10" FontWeight="Bold" FontFamily="{DynamicResource NumFont}" VerticalAlignment="Center" Margin="5,0,0,0"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- Escenario: el mapa ocupa todo el panel y los controles flotan encima de la pared -->
      <DockPanel x:Name="StagePanel" Grid.Row="1" Grid.RowSpan="4" Background="#101216" Visibility="Collapsed">
      <Border DockPanel.Dock="Bottom" Background="{DynamicResource Bg2}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="16,10">
        <DockPanel>
          <Button x:Name="StageBack" DockPanel.Dock="Right" Content="Volver al monitor  (Esc)" Style="{StaticResource TermBtn}"/>
          <TextBlock Style="{StaticResource Muted}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,10,0" Text="Clic derecho en un Claude para ver su ficha · arrástralo para moverlo"/>
        </DockPanel>
      </Border>
      <Grid x:Name="StageArea" ClipToBounds="True">
        <Viewbox Stretch="Fill">
          <Canvas x:Name="StageCanvas" Width="160" Height="260" RenderOptions.BitmapScalingMode="NearestNeighbor" TextOptions.TextFormattingMode="Ideal" TextOptions.TextHintingMode="Animated"/>
        </Viewbox>
        <Border VerticalAlignment="Top" Margin="8,6,8,0" Padding="10,3,4,3" CornerRadius="8" Background="#C8101216">
          <Border.Style>
            <Style TargetType="Border">
              <Setter Property="Opacity" Value="0.5"/>
              <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="1"/></Trigger></Style.Triggers>
            </Style>
          </Border.Style>
          <DockPanel>
            <Button x:Name="StageDone" DockPanel.Dock="Right" ToolTip="Volver al monitor (Esc)" Style="{StaticResource ChromeBtn}">
              <TextBlock Text="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#E5E7EB"/>
            </Button>
            <StackPanel VerticalAlignment="Center">
              <WrapPanel x:Name="StageOpts"/>
              <TextBlock x:Name="StageSummary" FontSize="10" Foreground="#AEB6C4" TextTrimming="CharacterEllipsis" Margin="2,1,0,1"/>
            </StackPanel>
          </DockPanel>
        </Border>
      </Grid>
      </DockPanel>

      <!-- Diario -->
      <Grid x:Name="DiaryPanel" Grid.Row="1" Grid.RowSpan="4" Background="{DynamicResource Bg}" Visibility="Collapsed">
        <DockPanel>
          <Border DockPanel.Dock="Bottom" Background="{DynamicResource Bg2}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="16,10">
            <DockPanel>
              <Button x:Name="DiaryDone" DockPanel.Dock="Right" Content="Volver al monitor  (Esc)" Style="{StaticResource TermBtn}"/>
              <TextBlock x:Name="DiaryNote" Style="{StaticResource Muted}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
            </DockPanel>
          </Border>
          <StackPanel DockPanel.Dock="Top" Margin="18,14,18,4">
            <TextBlock Text="Diario" Foreground="{DynamicResource Bright}" FontSize="18" FontWeight="Bold"/>
            <TextBlock x:Name="DiarySummary" Style="{StaticResource Muted}" Margin="0,2,0,8" TextWrapping="Wrap"/>
            <WrapPanel x:Name="DiaryScope"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="14,4,10,10">
            <StackPanel>
              <TextBlock x:Name="DiaryEmpty" Style="{StaticResource Muted}" Margin="4,10,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
              <ItemsControl x:Name="DiaryList">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                   <StackPanel Margin="0,0,0,6">
                    <DockPanel Margin="0,4,0,8">
                      <Border Style="{StaticResource Plate}">
                        <TextBlock Text="{Binding Header}" FontWeight="Bold" Foreground="{DynamicResource Bright}"/>
                      </Border>
                      <TextBlock DockPanel.Dock="Right" Text="{Binding Sub}" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center" Margin="8,0,0,0"/>
                      <Rectangle Height="1" Margin="8,0,0,0" VerticalAlignment="Center" Fill="{DynamicResource GroupLine}"/>
                    </DockPanel>
                    <ItemsControl ItemsSource="{Binding Sessions}">
                     <ItemsControl.ItemTemplate>
                      <DataTemplate>
                    <Border Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="{DynamicResource Radius}" Margin="0,0,0,8">
                      <Expander Style="{StaticResource DiaryExp}" IsExpanded="{Binding IsExpanded, Mode=TwoWay}">
                        <Expander.Header>
                          <StackPanel Margin="12,8,6,8">
                            <DockPanel>
                              <TextBlock DockPanel.Dock="Right" Text="{Binding LastText}" Style="{StaticResource Muted}" FontSize="10" VerticalAlignment="Center" Margin="8,0,0,0"/>
                              <Ellipse Width="8" Height="8" Fill="{Binding Color}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                              <TextBlock Text="{Binding Title}" FontWeight="Bold" FontSize="13" Foreground="{DynamicResource Bright}" TextTrimming="CharacterEllipsis"/>
                            </DockPanel>
                            <TextBlock Text="{Binding Summary}" Foreground="{DynamicResource Soft}" FontSize="10.5" Margin="16,2,0,0" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Text="{Binding Folder}" Style="{StaticResource Muted}" FontSize="10" Margin="16,1,0,0" TextTrimming="CharacterEllipsis"/>
                          </StackPanel>
                        </Expander.Header>
                        <ItemsControl ItemsSource="{Binding Turns}" Margin="12,0,12,10">
                          <ItemsControl.ItemTemplate>
                            <DataTemplate>
                              <Grid Margin="0,7,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="48"/><ColumnDefinition/></Grid.ColumnDefinitions>
                                <TextBlock Text="{Binding When}" Style="{StaticResource Muted}" FontSize="10.5" FontFamily="{DynamicResource NumFont}" Margin="4,1,0,0"/>
                                <Border Grid.Column="1" BorderBrush="{DynamicResource Deep}" BorderThickness="2,0,0,0" Padding="9,0,0,0">
                                  <StackPanel>
                                    <TextBlock Text="{Binding Prompt}" Foreground="{DynamicResource Text}" FontSize="11.5" TextWrapping="Wrap" MaxHeight="48" TextTrimming="CharacterEllipsis"/>
                                    <TextBlock Text="{Binding Detail}" Foreground="{DynamicResource Accent}" FontSize="10.5" TextWrapping="Wrap" Margin="0,2,0,0"/>
                                  </StackPanel>
                                </Border>
                              </Grid>
                            </DataTemplate>
                          </ItemsControl.ItemTemplate>
                        </ItemsControl>
                      </Expander>
                    </Border>
                      </DataTemplate>
                     </ItemsControl.ItemTemplate>
                    </ItemsControl>
                   </StackPanel>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </Grid>

      <!-- Ajustes -->
      <Grid x:Name="SettingsPanel" Grid.Row="1" Grid.RowSpan="4" Background="{DynamicResource Bg}" Visibility="Collapsed">
        <DockPanel>
          <Border DockPanel.Dock="Bottom" Background="{DynamicResource Bg2}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="16,10">
            <DockPanel>
              <Button x:Name="SettingsDone" DockPanel.Dock="Right" Content="Volver al monitor  (Esc)" Style="{StaticResource TermBtn}"/>
              <TextBlock x:Name="SettingsSaved" Style="{StaticResource Muted}" VerticalAlignment="Center" Text="Los cambios se guardan al momento."/>
            </DockPanel>
          </Border>
          <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18,14,10,14">
            <StackPanel>
              <TextBlock Text="Ajustes" Foreground="{DynamicResource Bright}" FontSize="18" FontWeight="Bold"/>

              <TextBlock Text="APARIENCIA" Style="{StaticResource Section}"/>
              <StackPanel x:Name="StyleOpts"/>
              <StackPanel x:Name="HackerOpts" Margin="0,10,0,4">
                <TextBlock Text="Opciones del estilo Hacker" Foreground="{DynamicResource Bright}" FontWeight="SemiBold" Margin="0,0,0,6"/>
                <TextBlock Text="Paleta" Foreground="{DynamicResource Soft}" Margin="0,0,0,4"/>
                <WrapPanel x:Name="ThemeOpts"/>
                <CheckBox x:Name="CrtChk" Style="{StaticResource TermCheck}" Content="Efecto CRT (líneas de barrido y viñeta)" Margin="0,4,0,0"/>
              </StackPanel>
              <StackPanel x:Name="NefOpts" Margin="0,10,0,4">
                <TextBlock Text="Opciones del estilo Nefralis" Foreground="{DynamicResource Bright}" FontWeight="SemiBold" Margin="0,0,0,6"/>
                <TextBlock Text="Fondo" Foreground="{DynamicResource Soft}" Margin="0,0,0,4"/>
                <WrapPanel x:Name="NefFondoOpts"/>
              </StackPanel>
              <Border Height="8"/>
              <CheckBox x:Name="SpritesChk" Style="{StaticResource TermCheck}" Content="Claudes animados en pixel art en cada sesión (cada estado tiene varias escenas)"/>
              <Button x:Name="GalleryBtn" Style="{StaticResource TermBtn}" Content="Ver todas las animaciones de Claude por estado" HorizontalAlignment="Left" Margin="22,4,0,6"/>

              <TextBlock Text="CUÁNDO ABRIR LA VENTANA" Style="{StaticResource Section}"/>
              <StackPanel x:Name="OpenOpts"/>
              <WrapPanel x:Name="RamOpts" Margin="22,0,0,0"/>
              <TextBlock Text="En cualquier modo puedes abrirla a mano escribiendo /monitor en Claude Code." Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,6,0,0"/>

              <TextBlock Text="LISTA DE SESIONES" Style="{StaticResource Section}"/>
              <TextBlock Text="Agrupar" Foreground="{DynamicResource Soft}" Margin="0,0,0,4"/>
              <StackPanel x:Name="GroupOpts"/>
              <TextBlock Text="Ordenar dentro de cada grupo" Foreground="{DynamicResource Soft}" Margin="0,8,0,4"/>
              <StackPanel x:Name="SortOpts"/>

              <TextBlock Text="RENDIMIENTO" Style="{StaticResource Section}"/>
              <TextBlock Text="Actualizar cada" Foreground="{DynamicResource Soft}" Margin="0,0,0,4"/>
              <WrapPanel x:Name="RefreshOpts"/>
              <TextBlock Text="RAM de reserva (lo que el consejo deja siempre libre)" Foreground="{DynamicResource Soft}" Margin="0,8,0,4"/>
              <WrapPanel x:Name="ReserveOpts"/>

              <TextBlock Text="AVISOS Y VENTANA" Style="{StaticResource Section}"/>
              <CheckBox x:Name="SoundCritChk" Style="{StaticResource TermCheck}" Content="Sonido de aviso cuando la RAM entra en zona crítica (90 % o más)"/>
              <CheckBox x:Name="SoundDoneChk" Style="{StaticResource TermCheck}" Content="Sonido cuando una sesión termina su tarea"/>
              <CheckBox x:Name="TopChk" Style="{StaticResource TermCheck}" Content="Ventana siempre visible (encima de las demás)"/>
              <CheckBox x:Name="DockChk" Style="{StaticResource TermCheck}" Content="Acoplar con Windows Terminal: el monitor pegado a la derecha con el ancho mínimo y toda la altura, y la Terminal ocupando el resto a la izquierda. Mientras esté activado no se pueden mover ni cambiar de tamaño"/>
              <CheckBox x:Name="FixedChk" Style="{StaticResource TermCheck}" Content="Tamaño fijo: deja la ventana como quieras y actívalo para que se quede con ese tamaño"/>

              <TextBlock Text="SOBRE PAUSAR" Style="{StaticResource Section}"/>
              <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" LineHeight="16"
                         Text="Pausar congela la sesión y todos sus procesos (no gasta CPU) y mueve su memoria al archivo de paginación, liberando RAM. Al reanudar sigue donde estaba. Si cierras el monitor, las sesiones en pausa se reanudan solas."/>
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </Grid>

      <!-- Efecto CRT (estilo Hacker) -->
      <Rectangle x:Name="Scanlines" Grid.RowSpan="5" IsHitTestVisible="False">
        <Rectangle.Fill>
          <DrawingBrush TileMode="Tile" Viewport="0,0,4,3" ViewportUnits="Absolute" Opacity="0.05">
            <DrawingBrush.Drawing>
              <GeometryDrawing Brush="{DynamicResource Accent}"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,4,1"/></GeometryDrawing.Geometry></GeometryDrawing>
            </DrawingBrush.Drawing>
          </DrawingBrush>
        </Rectangle.Fill>
      </Rectangle>
      <Rectangle x:Name="Vignette" Grid.RowSpan="5" IsHitTestVisible="False">
        <Rectangle.Fill>
          <RadialGradientBrush RadiusX="0.75" RadiusY="0.65">
            <GradientStop Color="#00000000" Offset="0.6"/><GradientStop Color="#66000000" Offset="1"/>
          </RadialGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
    </Grid>
  </Border>
</Window>
'@

# Ojo: el dibujado por software ahorraba ~40 MB pero subía la CPU del 2 % a más del 20 % de un núcleo; se queda en la gráfica
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $n = $window.FindName($_.Name); if ($n) { $ui[$_.Name] = $n } }
# El XAML y el código C# solo hacen falta al arrancar
$xaml = $null; $nativeSource = $null

# Esquina inferior derecha del área de trabajo, sin pasarse de alto.
$area = [System.Windows.SystemParameters]::WorkArea
$window.Height = [Math]::Min($window.Height, $area.Height - 32)
$window.Left = $area.Right - $window.Width - 16
$window.Top = $area.Bottom - $window.Height - 16
# Tamaño fijo: guarda el tamaño y la posición que tenga la ventana al activarlo y los respeta al abrirse
function Save-Bounds { $settings.fixedBounds = @([int]$window.Left, [int]$window.Top, [int]$window.Width, [int]$window.Height); Save-Settings }
function Apply-WindowSize([bool]$capture) {
  if (-not $settings.fixedSize) { $window.ResizeMode = 'CanResize'; return }
  if ($window.WindowState -ne 'Normal') { $window.WindowState = 'Normal' }
  $b = @($settings.fixedBounds)
  if ($capture -or $b.Count -ne 4) { Save-Bounds }
  else {
    # Dentro del escritorio aunque haya cambiado la pantalla
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.Width = [Math]::Max($window.MinWidth, [Math]::Min([double]$b[2], $area.Width))
    $window.Height = [Math]::Max($window.MinHeight, [Math]::Min([double]$b[3], $area.Height))
    $window.Left = [Math]::Max($area.Left, [Math]::Min([double]$b[0], $area.Right - $window.Width))
    $window.Top = [Math]::Max($area.Top, [Math]::Min([double]$b[1], $area.Bottom - $window.Height))
  }
  $window.ResizeMode = 'NoResize'
}
Apply-WindowSize $false

# Acoplado con Windows Terminal: el monitor fijo a la derecha y la Terminal ocupando el resto, a la izquierda
function Terminal-Window {
  $wt = Get-Process WindowsTerminal | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
  if ($wt) { $wt.MainWindowHandle } else { [IntPtr]::Zero }
}
# Proporción fija: el monitor con su ancho mínimo y toda la altura, pegado a la derecha; ni se mueve ni cambia de tamaño.
# La Terminal tampoco se queda maximizada; $force (al activarlo o al abrir) también la saca de minimizada.
function Apply-Dock([bool]$force) {
  [TaskMon.Native]::Locked = [bool]$settings.dockTerminal
  if (-not $settings.dockTerminal) { return }
  if ($window.WindowState -eq 'Minimized') { return }
  if ($window.WindowState -ne 'Normal') { $window.WindowState = 'Normal' }
  $window.ResizeMode = 'NoResize'
  $area = [System.Windows.SystemParameters]::WorkArea
  $left = $area.Right - $window.MinWidth
  if ($window.Width -ne $window.MinWidth) { $window.Width = $window.MinWidth }
  if ($window.Height -ne $area.Height) { $window.Height = $area.Height }
  if ($window.Top -ne $area.Top) { $window.Top = $area.Top }
  if ($window.Left -ne $left) { $window.Left = $left }
  $src = [System.Windows.PresentationSource]::FromVisual($window)
  if (-not $src) { return }
  $k = $src.CompositionTarget.TransformToDevice.M11
  $term = Terminal-Window
  [TaskMon.Native]::Restore($term, $force)
  $me = [TaskMon.Native]::WindowRect((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle)
  $x = [int][Math]::Round($area.Left * $k); $y = [int][Math]::Round($area.Top * $k)
  $w = $me[0] - $x; $h = [int][Math]::Round($area.Height * $k)
  if ($w -gt 200) { [void][TaskMon.Native]::PlaceVisible($term, $x, $y, $w, $h) }
}
# Si algo lo mueve o le cambia el tamaño (Win+flechas, otra pantalla...), vuelve a su sitio
$dockTimer = New-Object System.Windows.Threading.DispatcherTimer
$dockTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$dockTimer.Add_Tick({ $dockTimer.Stop(); Apply-Dock $false })
$window.Add_SizeChanged({ if ($settings.dockTerminal) { $dockTimer.Stop(); $dockTimer.Start() } })
$window.Add_LocationChanged({ if ($settings.dockTerminal) { $dockTimer.Stop(); $dockTimer.Start() } })
# Con el tamaño fijo se puede seguir moviendo: la nueva posición se guarda al soltarla
$boundsTimer = New-Object System.Windows.Threading.DispatcherTimer
$boundsTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$boundsTimer.Add_Tick({ $boundsTimer.Stop(); if ($settings.fixedSize -and -not $settings.dockTerminal -and $window.WindowState -eq 'Normal') { Save-Bounds } })
$window.Add_LocationChanged({ if ($settings.fixedSize) { $boundsTimer.Stop(); $boundsTimer.Start() } })

$window.Add_SourceInitialized({
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
  $round = 2; [void][TaskMon.Native]::DwmSetWindowAttribute($hwnd, 33, [ref]$round, 4)
  [TaskMon.Native]::LockHook([System.Windows.Interop.HwndSource]::FromHwnd($hwnd))
})

# Parpadeo (cursor y punto de las sesiones en curso): la opacidad que guarda Window.Tag, cambiada dos veces por segundo.
# Una animación continua de WPF redibuja la ventana sin parar y era lo que más CPU gastaba.
$window.Tag = [double]1
$pulse = New-Object System.Windows.Threading.DispatcherTimer
$pulse.Interval = [TimeSpan]::FromMilliseconds(600)
$pulse.Add_Tick({ $window.Tag = [double]$(if ([double]$window.Tag -gt 0.5) { 0.25 } else { 1 }) })
$pulse.Start()

# --- Helpers ---------------------------------------------------------------
function Color([string]$hex) { [System.Windows.Media.ColorConverter]::ConvertFromString($hex) }
function Brush([string]$hex) { $b = New-Object System.Windows.Media.SolidColorBrush (Color $hex); $b.Freeze(); $b }
function Alpha([string]$hex, [string]$aa) { '#' + $aa + $hex.TrimStart('#').Substring([Math]::Max(0, $hex.TrimStart('#').Length - 6)) }
function Fill([string]$hex, [int]$top = 0x50) {
  $c = Color $hex
  $g = New-Object System.Windows.Media.LinearGradientBrush
  $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
  $g.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb($top, $c.R, $c.G, $c.B), 0))
  $g.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x00, $c.R, $c.G, $c.B), 1))
  $g
}
function Format-MB([double]$mb) {
  if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb }
}
function Format-Ago([double]$ms) {
  $s = [int][Math]::Floor($ms / 1000)
  if ($s -lt 60) { '{0}s' -f $s } elseif ($s -lt 3600) { '{0}m {1:00}s' -f [int][Math]::Floor($s / 60), ($s % 60) } else { '{0}h {1:00}m' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60) }
}
function Format-Tokens([double]$n) {
  if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1e6) } elseif ($n -ge 1000) { '{0:N0}k' -f ($n / 1e3) } else { '{0:N0}' -f $n }
}
$typers = @{}
function Type-Text($tb, [string]$text) {
  if ($tb.Tag -eq $text) { return }
  $tb.Tag = $text
  if ($typers[$tb.Name]) { $typers[$tb.Name].Stop() }
  if (-not $style.Glow) { $tb.Text = $text; return }
  $state = @{ i = 0 }
  $t = New-Object System.Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds(16)
  $t.Add_Tick({
    $state.i += 3
    if ($state.i -ge $text.Length) { $tb.Text = $text; $t.Stop() } else { $tb.Text = $text.Substring(0, $state.i) + '█' }
  }.GetNewClosure())
  $typers[$tb.Name] = $t
  $t.Start()
}
function Push($list, [double]$value, [int]$max) {
  $list.Add($value)
  while ($list.Count -gt $max) { $list.RemoveAt(0) }
}
# Gráfica de puntos: línea fina + un punto por muestra (+ rejilla, ejes y relleno según el estilo).
# Los puntos son una sola figura y la rejilla solo se rehace si cambia el tamaño o el estilo.
$graphGrid = @{}
$brushCache = @{}
function Brush-Cached([string]$hex) { if (-not $brushCache.ContainsKey($hex)) { $brushCache[$hex] = Brush $hex }; $brushCache[$hex] }
function Fill-Cached([string]$hex) { $k = "fill$hex"; if (-not $brushCache.ContainsKey($k)) { $f = Fill $hex 0x38; $f.Freeze(); $brushCache[$k] = $f }; $brushCache[$k] }
function Dots-Cached([string]$hex) {
  $k = "dots$hex"
  if (-not $brushCache.ContainsKey($k)) {
    $c = Color $hex
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = '0,0'; $g.EndPoint = '1,0'
    $g.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x50, $c.R, $c.G, $c.B), 0))
    $g.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0xFF, $c.R, $c.G, $c.B), 1))
    $g.Freeze(); $brushCache[$k] = $g
  }
  $brushCache[$k]
}
function Draw-Graph([string]$key, $canvas, $line, $area, $dots, $head, $values, [string]$color) {
  $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
  if ($w -le 0) { return }
  $left = if ($style.Axis) { 24 } else { 0 }
  $sig = "$w|$h|$($settings.style)|$($settings.theme)"
  $grid = $graphGrid[$key]
  if (-not $grid -or $grid.Sig -ne $sig) {
    if ($grid) { foreach ($el in $grid.Els) { $canvas.Children.Remove($el) } }
    $els = New-Object System.Collections.Generic.List[object]
    if ($style.Grid) {
      foreach ($pct in 0, 50, 100) {
        $y = $h - ($pct / 100 * ($h - 4)) - 2
        $gl = New-Object System.Windows.Shapes.Line
        $gl.X1 = $left; $gl.X2 = $w; $gl.Y1 = $y; $gl.Y2 = $y
        $gl.Stroke = $theme.Line; $gl.StrokeThickness = 1
        if ($settings.style -eq 'trading') { $gl.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('3 3') }
        [void]$canvas.Children.Insert(0, $gl); $els.Add($gl)
        if ($style.Axis) {
          $lb = New-Object System.Windows.Controls.TextBlock
          $lb.Text = "$pct"; $lb.FontSize = 8; $lb.Foreground = $theme.Dim; $lb.FontFamily = $style.Num
          [System.Windows.Controls.Canvas]::SetLeft($lb, 0); [System.Windows.Controls.Canvas]::SetTop($lb, [Math]::Max(-2, [Math]::Min($h - 11, $y - 6)))
          [void]$canvas.Children.Insert(0, $lb); $els.Add($lb)
        }
      }
    }
    $graphGrid[$key] = @{ Sig = $sig; Els = $els }
  }

  $pts = [TaskMon.Geo]::Spark($values.ToArray(), $w - $left - 4, $h, $historyLen, 100, $left)
  $brush = Brush-Cached $color
  $line.Points = $pts
  $line.Stroke = $brush
  $line.Opacity = $(if ($style.Dots) { 0.55 } else { 1 })
  if ($style.Area -and $pts.Count) {
    $poly = New-Object System.Windows.Media.PointCollection ($pts.Count + 2)
    $poly.Add([System.Windows.Point]::new($pts[0].X, $h))
    foreach ($p in $pts) { $poly.Add($p) }
    $poly.Add([System.Windows.Point]::new($pts[$pts.Count - 1].X, $h))
    $area.Points = $poly
    $area.Fill = Fill-Cached $color
  } else { $area.Points = $null }
  if ($style.Dots -and $pts.Count -gt 1) { $dots.Data = [TaskMon.Geo]::Dots($pts, 1.5); $dots.Fill = Dots-Cached $color } else { $dots.Data = $null }
  if ($pts.Count) {
    $last = $pts[$pts.Count - 1]
    $head.Visibility = 'Visible'
    $head.Fill = $brush
    [System.Windows.Controls.Canvas]::SetLeft($head, $last.X - 3); [System.Windows.Controls.Canvas]::SetTop($head, $last.Y - 3)
    if ($style.Glow) {
      if (-not $head.Effect) { $fx = New-Object System.Windows.Media.Effects.DropShadowEffect; $fx.ShadowDepth = 0; $fx.BlurRadius = 10; $head.Effect = $fx }
      $head.Effect.Color = Color $color
    } else { $head.Effect = $null }
  } else { $head.Visibility = 'Collapsed' }
}

$logItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.Log.ItemsSource = $logItems
function Log([string]$text, [string]$color = '') {
  try { [IO.File]::AppendAllText((Join-Path $dataDir 'actividad.log'), "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $text`r`n") } catch {}
  if (-not $color) { $color = $theme.Accent }
  $logItems.Add([pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss  '); Text = $text; Color = $color })
  while ($logItems.Count -gt 80) { $logItems.RemoveAt(0) }
  $ui.LogScroll.ScrollToEnd()
}

# --- Estilo y tema -------------------------------------------------------------
$assetDir = Join-Path $PSScriptRoot 'assets'
# Una imagen que falta no debe tumbar la ventana: sin archivo, sin imagen
function Load-Image([string]$path) {
  if (-not [IO.File]::Exists($path)) { return $null }
  try {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.UriSource = [Uri]$path; $bi.EndInit(); $bi.Freeze()
    $bi
  } catch { $null }
}
$style = $styles['hacker']; $theme = $themes['matrix']
$labels = @{
  hacker   = @{ Cpu = '[ CPU ]'; Ram = '[ MEM ]'; Slots = 'SLOTS '; Tasks = '> ps --claude'; Others = '> top --mem --exclude claude'; Log = '> tail -f events.log'; Pinned = '-- fijadas'; Rest = '-- resto'; Title = 'claude@task-monitor' }
  simple   = @{ Cpu = 'CPU'; Ram = 'MEMORIA'; Slots = 'Huecos  '; Tasks = 'Sesiones de Claude'; Others = 'Otros programas que más memoria usan'; Log = 'Actividad'; Pinned = 'Fijadas'; Rest = 'Sin fijar'; Title = 'Claude Task Monitor' }
  analytic = @{ Cpu = 'USO DE CPU %'; Ram = 'USO DE RAM %'; Slots = 'CAPACIDAD  '; Tasks = 'SESIONES · DESGLOSE'; Others = 'CONSUMO DE MEMORIA POR PROGRAMA'; Log = 'REGISTRO DE EVENTOS'; Pinned = 'FIJADAS'; Rest = 'RESTO'; Title = 'Claude Code · Panel de rendimiento' }
  nefralis = @{ Cpu = 'CPU'; Ram = 'MEMORIA'; Slots = 'HUECOS  '; Tasks = 'SESIONES DE CLAUDE'; Others = 'OTROS PROGRAMAS'; Log = 'ACTIVIDAD'; Pinned = 'FIJADAS'; Rest = 'SIN FIJAR'; Title = 'MONITOR DE CLAUDE' }
  trading  = @{ Cpu = 'CPU/SYS'; Ram = 'RAM/SYS'; Slots = 'POSICIONES  '; Tasks = 'CARTERA DE SESIONES'; Others = 'OTROS ACTIVOS (MEMORIA)'; Log = 'ÓRDENES Y EVENTOS'; Pinned = 'FAVORITAS'; Rest = 'RESTO DE LA CARTERA'; Title = 'CLAUDE/SYS' }
}
# En Nefralis los rótulos van espaciados, como sus títulos (letterSpacing): un espacio fino entre letras
function Spaced([string]$text) { if ($settings.style -ne 'nefralis') { return $text }; $text.ToCharArray() -join [char]0x200A }
$assetCache = @{}
function Asset-Image([string]$file) {
  if (-not $assetCache.ContainsKey($file)) { $assetCache[$file] = Load-Image (Join-Path $assetDir $file) }
  $assetCache[$file]
}
function Apply-Style {
  $script:style = if ($styles.Contains($settings.style)) { $styles[$settings.style] } else { $styles['hacker'] }
  $isHacker = $settings.style -eq 'hacker'
  $palette = if ($isHacker) { if ($themes.Contains($settings.theme)) { $themes[$settings.theme] } else { $themes['matrix'] } } else { $style.Palette }
  $script:theme = $palette
  foreach ($k in $palette.Keys) { if ($k -ne 'Name') { $window.Resources[$k] = [System.Windows.Media.Brush](Brush $palette[$k]) } }
  $window.Resources['UiFont'] = [System.Windows.Media.FontFamily]::new($style.Font)
  $window.Resources['NumFont'] = [System.Windows.Media.FontFamily]::new($style.Num)
  $window.Resources['Radius'] = [System.Windows.CornerRadius]::new($style.Radius)
  $window.FontFamily = [System.Windows.Media.FontFamily]::new($style.Font)
  $ui.Scanlines.Visibility = $(if ($isHacker -and $settings.crt) { 'Visible' } else { 'Collapsed' })
  $ui.Vignette.Visibility = $ui.Scanlines.Visibility
  # Mismo encabezado en todos los estilos: título y, debajo, el resumen (antes el de Hacker y el ticker se iban a la derecha y pisaban los botones)
  $ui.HackerTitle.Visibility = 'Collapsed'; $ui.Ticker.Visibility = 'Collapsed'
  $ui.PlainTitle.Visibility = 'Visible'; $ui.TitleSub.Visibility = 'Visible'
  if ($isHacker) { $ui.PlainTitle.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Accent') }
  else { $ui.PlainTitle.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Bright') }
  $l = $labels[$settings.style]
  $ui.PlainTitle.Text = Spaced $l.Title
  $ui.CpuTag.Text = Spaced $l.Cpu; $ui.RamTag.Text = Spaced $l.Ram; $ui.SlotsTag.Text = $l.Slots
  $ui.TasksTag.Text = Spaced $l.Tasks; $ui.OthersTag.Text = Spaced $l.Others; $ui.LogTag.Text = Spaced $l.Log
  $isUpper = $settings.style -in 'nefralis', 'analytic', 'trading'
  $ui.RenderTag.Text = $(if ($settings.style -eq 'hacker') { '> render --watch' } else { Spaced $(if ($isUpper) { 'RENDERS EN CURSO' } else { 'Renders en curso' }) })
  $ui.RenderPausedTag.Text = $(if ($settings.style -eq 'hacker') { '-- en pausa' } else { Spaced $(if ($isUpper) { 'EN PAUSA' } else { 'En pausa' }) })
  $ui.RenderOthersTag.Text = Spaced $l.Others
  $ui.RenderWaitTag.Text = $(if ($settings.style -eq 'hacker') { '-- en espera' } else { Spaced $(if ($isUpper) { 'EN ESPERA' } else { 'En espera' }) })
  $ui.RenderDoneTag.Text = $(if ($settings.style -eq 'hacker') { '-- terminados (24 h)' } else { Spaced $(if ($isUpper) { 'TERMINADOS (24 H)' } else { 'Terminados (24 h)' }) })
  $ui.NavTasksText.Text = $(if ($settings.style -eq 'hacker') { 'claude tasks' } elseif ($isUpper) { Spaced 'CLAUDE TASKS' } else { 'Claude Tasks' })
  $ui.NavRenderText.Text = $(if ($settings.style -eq 'hacker') { 'render' } elseif ($isUpper) { Spaced 'RENDER' } else { 'Render' })
  $script:slotsSig = ''
  $glow = $(if ($style.Glow) { 0.75 } elseif ($settings.style -eq 'nefralis') { 0.55 } else { 0 })
  $ui.CpuGlow.Opacity = $glow; $ui.RamGlow.Opacity = $glow
  $ui.CpuStats.Visibility = $(if ($style.Stats -or $style.Delta) { 'Visible' } else { 'Collapsed' })
  $ui.RamStats.Visibility = $ui.CpuStats.Visibility
  $ui.CpuDelta.Visibility = $(if ($style.Delta) { 'Visible' } else { 'Collapsed' }); $ui.RamDelta.Visibility = $ui.CpuDelta.Visibility
  $ui.HackerOpts.Visibility = $(if ($isHacker) { 'Visible' } else { 'Collapsed' })
  $isNef = $settings.style -eq 'nefralis'
  $ui.NefOpts.Visibility = $(if ($isNef) { 'Visible' } else { 'Collapsed' })
  $window.Resources['Plate'] = [System.Windows.Media.Brush](Brush $(if ($isNef) { '#8C000000' } else { '#00000000' }))
  $window.Resources['PlatePad'] = [System.Windows.Thickness]::new($(if ($isNef) { 8 } else { 0 }), $(if ($isNef) { 3 } else { 0 }), $(if ($isNef) { 8 } else { 0 }), $(if ($isNef) { 3 } else { 0 }))
  $window.Resources['PlateBarVis'] = [System.Windows.Visibility]$(if ($isNef) { 'Visible' } else { 'Collapsed' })
  $window.Resources['HeaderBg'] = [System.Windows.Media.Brush](Brush $(if ($isNef) { '#4D0E0F11' } else { $palette.Bg }))
  $window.Resources['SpriteBg'] = [System.Windows.Media.Brush](Brush $(if ($isNef) { '#26282C' } else { $palette.Bg }))
  $gl = New-Object System.Windows.Media.LinearGradientBrush (Color (Alpha $palette.Accent 'AA')), (Color (Alpha $palette.Accent '00')), 0.0
  $gl.Freeze(); $window.Resources['GroupLine'] = [System.Windows.Media.Brush]$gl
  $ui.BgGlow.Visibility = $(if ($isNef) { 'Visible' } else { 'Collapsed' })
  $window.Resources['CardGap'] = [System.Windows.Thickness]::new(0, 0, 0, $(if ($isNef) { 8 } else { 5 }))
  $ui.MainScroll.Padding = $(if ($isNef) { [System.Windows.Thickness]::new(14, 12, 10, 8) } else { [System.Windows.Thickness]::new(10, 8, 6, 6) })
  $ui.RenderScroll.Padding = $ui.MainScroll.Padding
  $ui.CpuMark.Visibility = $ui.BgGlow.Visibility; $ui.RamMark.Visibility = $ui.BgGlow.Visibility
  $ui.AdviceMedal.Visibility = $ui.BgGlow.Visibility; $ui.NoTasksMedal.Visibility = $ui.BgGlow.Visibility
  $ui.PlainTitle.FontSize = $(if ($isNef) { 12 } else { 13 }); $ui.PlainTitle.FontWeight = $(if ($isNef) { 'Bold' } else { 'SemiBold' })
  $ui.AccentLine.Visibility = $(if ($isNef) { 'Visible' } else { 'Collapsed' })
  $ui.BgVeil.Visibility = $(if ($isNef) { 'Visible' } else { 'Collapsed' })
  $ui.BgImage.Visibility = $ui.BgVeil.Visibility
  $ui.TitleIcon.Visibility = $(if ($isNef) { 'Collapsed' } else { 'Visible' })
  $ui.NefIcon.Visibility = $(if ($isNef) { 'Visible' } else { 'Collapsed' })
  if ($isNef) {
    $img = Join-Path $assetDir "nefralis-$($settings.nefFondo).jpg"
    if (-not (Test-Path -LiteralPath $img)) { $img = Join-Path $assetDir 'nefralis-estatua.jpg' }
    $bi = Load-Image $img
    if ($bi) {
      $brush = New-Object System.Windows.Media.ImageBrush $bi
      $brush.Stretch = 'UniformToFill'; $brush.AlignmentY = 'Top'; $brush.Freeze()
      $ui.BgImage.Fill = $brush
    } else { $ui.BgImage.Fill = $null }
    $ui.CpuMark.Source = Asset-Image 'icon-entrenamiento.png'; $ui.RamMark.Source = Asset-Image 'icon-record.png'
    $ui.NoTasksIcon.Source = Asset-Image 'icon-vacio.png'

    $icon = Load-Image (Join-Path $assetDir 'nefralis-icon.png')
    if (-not $ui.NefIcon.Fill -and $icon) { $ui.NefIcon.Fill = [System.Windows.Media.ImageBrush]::new($icon) }
    # Subtítulos como en Nefralis: texto claro en mayúsculas sobre placa oscura, con la barrita del acento
    foreach ($tag in $ui.TasksTag, $ui.OthersTag, $ui.RenderTag, $ui.RenderWaitTag, $ui.RenderPausedTag, $ui.RenderDoneTag, $ui.RenderOthersTag) { $tag.Foreground = Brush $palette.Bright; $tag.FontSize = 12 }
  } else {
    $ui.BgImage.Fill = $null

    foreach ($tag in $ui.TasksTag, $ui.OthersTag, $ui.RenderTag, $ui.RenderWaitTag, $ui.RenderPausedTag, $ui.RenderDoneTag, $ui.RenderOthersTag) { $tag.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Accent'); $tag.FontSize = 11 }
  }
  $ui.AdviceTitle.Tag = $null
  $script:groupOrderSig = ''
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
  if ($hwnd -ne [IntPtr]::Zero) {
    $c = Color $theme.Line; $border = [int]$c.R + ([int]$c.G -shl 8) + ([int]$c.B -shl 16)
    [void][TaskMon.Native]::DwmSetWindowAttribute($hwnd, 34, [ref]$border, 4)
  }
}
Apply-Style
$window.Add_SourceInitialized({ Apply-Style })

# --- Pausa / reanudar -------------------------------------------------------------
$treeOf = @{}          # pid raíz -> pids de su árbol que se pueden congelar (última lectura)
$resumeUntil = @{}     # pid raíz -> fin del estado "reanudando"
function Pause-Session($item) {
  $rootPid = [int]$item['Pid']
  $pids = @($treeOf[$rootPid]); if (-not $pids.Count) { $pids = @($rootPid) }
  $before = [double]$item['MemMB']
  $ok = 0
  foreach ($id in $pids) { if ([TaskMon.Native]::Suspend($id)) { $ok++ } }
  foreach ($id in $pids) { [void][TaskMon.Native]::Trim($id) }
  if (-not $ok) { Log "no se pudo pausar $($item['Title'])" $crit; return }
  $paused[$rootPid] = @{ since = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); pids = $pids }
  Save-Paused
  Log "❚❚ $($item['Title']) en pausa · $ok procesos congelados · su RAM ($(Format-MB $before)) pasa al archivo de paginación" $stateInfo.paused.Color
  Refresh
}
function Resume-Session($item) {
  $rootPid = [int]$item['Pid']
  $entry = $paused[$rootPid]
  $pids = @(@($entry.pids) + @($treeOf[$rootPid]) | Where-Object { $_ } | Select-Object -Unique)
  Thaw-Pids $pids
  $paused.Remove($rootPid); Save-Paused
  $resumeUntil[$rootPid] = (Get-Date).AddSeconds(2)
  Log "▶ reanudando $($item['Title'])..." $resumeColor
  Refresh
  $t = New-Object System.Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds(2050)
  $t.Tag = $rootPid
  $t.Add_Tick({ param($s) $s.Stop(); $script:resumeUntil.Remove([int]$s.Tag); Refresh })
  $t.Start()
}
function Resume-All {
  foreach ($k in @($paused.Keys)) { foreach ($id in @($paused[$k].pids)) { [void][TaskMon.Native]::Resume([int]$id) } }
  $paused.Clear(); Save-Paused
}

# Descongela del todo: NtResumeProcess solo resta una vez, y un proceso pudo quedar congelado dos veces
function Thaw-Pids($pids) { foreach ($x in @($pids)) { if ($x) { for ($i = 0; $i -lt 4; $i++) { [void][TaskMon.Native]::Resume([int]$x) } } } }
# --- Nombres --------------------------------------------------------------------
function Meta-Keys($item) {
  $keys = @("pid:$($item['Pid'])")
  if ($item['SessionId']) { $keys = @("$($item['SessionId'])") + $keys }
  $keys
}
function Get-Meta($item, [string]$field) {
  foreach ($k in (Meta-Keys $item)) { if ($meta.ContainsKey($k) -and $meta[$k][$field]) { return $meta[$k][$field] } }
}
function Set-Meta($item, [string]$field, $value) {
  foreach ($k in (Meta-Keys $item)) {
    if (-not $meta.ContainsKey($k)) { $meta[$k] = @{} }
    if ($null -eq $value -or $value -eq '' -or $value -eq $false) { $meta[$k].Remove($field) } else { $meta[$k][$field] = $value }
  }
  Save-Meta
}

# Lleva a la terminal de la sesión. En Windows Terminal busca la pestaña por su título (el mismo que pone Claude) y la selecciona.
$uiaLoaded = $false
function Strip-Title([string]$t) { ($t -replace '^[^\p{L}\p{N}]+', '').Trim() }
# Dónde vive la sesión: su pestaña de Windows Terminal (Tab, Win) si la hay, o su ventana de consola (Target)
function Find-Terminal($item) {
  $p = [int]$item['Pid']
  $raw = [TaskMon.Native]::ConsoleTitle($p)
  $want = Strip-Title $(if ($raw) { $raw } else { [string]$item['LastWindow'] })
  $con = [TaskMon.Native]::ConsoleWindow($p)
  $owner = [TaskMon.Native]::Owner($con)
  $r = @{ Tab = $null; Win = $null; Wins = @(); Target = $(if ($owner -ne [IntPtr]::Zero) { $owner } else { $con }) }
  # ¿Windows Terminal? Por el dueño de su ventana de consola o porque cuelga de WindowsTerminal.exe
  $wtPid = 0
  if ($owner -ne [IntPtr]::Zero) { $op = [TaskMon.Native]::WindowPid($owner); if ((Get-Process -Id $op).ProcessName -eq 'WindowsTerminal') { $wtPid = $op } }
  if (-not $wtPid) {
    $tree = New-Object TaskMon.Tree (, [TaskMon.Native]::Snapshot())
    $x = $tree.ById[$p]
    for ($i = 0; $i -lt 8 -and $x; $i++) { if ($x.Name -eq 'WindowsTerminal.exe') { $wtPid = $x.Pid; break }; $x = $tree.ById[$x.Ppid] }
  }
  if ($wtPid -and $want) {
    if (-not $script:uiaLoaded) { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes; $script:uiaLoaded = $true }
    $AE = [System.Windows.Automation.AutomationElement]
    $r.Wins = if ($owner -ne [IntPtr]::Zero -and [TaskMon.Native]::WindowPid($owner) -eq $wtPid) { @($AE::FromHandle($owner)) }
      else { @($AE::RootElement.FindAll('Children', (New-Object System.Windows.Automation.PropertyCondition $AE::ProcessIdProperty, $wtPid))) }
    $tabCond = New-Object System.Windows.Automation.PropertyCondition $AE::ControlTypeProperty, ([System.Windows.Automation.ControlType]::TabItem)
    foreach ($w in $r.Wins) {
      $tab = $w.FindAll('Descendants', $tabCond) | Where-Object { (Strip-Title $_.Current.Name) -eq $want } | Select-Object -First 1
      if ($tab) { $r.Tab = $tab; $r.Win = $w; break }
    }
  }
  $r
}
function Focus-Session($item) {
  $t = Find-Terminal $item
  if ($t.Tab) {
    try { $t.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch {}
    [void][TaskMon.Native]::Focus([IntPtr]$t.Win.Current.NativeWindowHandle)
    Log "→ $($item['Title']): su pestaña de Windows Terminal" $theme.Accent2
    return
  }
  if ($t.Wins.Count) { [void][TaskMon.Native]::Focus([IntPtr]$t.Wins[0].Current.NativeWindowHandle); Log "→ $($item['Title']): no encontré su pestaña; abro Windows Terminal" $warn; return }
  if ([TaskMon.Native]::Focus($t.Target)) { Log "→ $($item['Title']): su ventana de terminal" $theme.Accent2 }
  else { Log "no encontré la terminal de $($item['Title'])" $warn }
}

# Diálogo propio con los colores del tema: sí/no, encima del monitor
function Confirm-Dialog([string]$title, [string]$text, [string]$okText) {
  $dlg = New-Object System.Windows.Window
  $dlg.WindowStyle = 'None'; $dlg.AllowsTransparency = $true; $dlg.Background = [System.Windows.Media.Brushes]::Transparent
  $dlg.ResizeMode = 'NoResize'; $dlg.SizeToContent = 'WidthAndHeight'; $dlg.ShowInTaskbar = $false
  $dlg.Owner = $window; $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.Topmost = $window.Topmost
  foreach ($k in $theme.Keys) { if ($k -ne 'Name') { $dlg.Resources[$k] = [System.Windows.Media.Brush](Brush $theme[$k]) } }
  $dlg.Resources['Radius'] = [System.Windows.CornerRadius]::new($style.Radius)
  $box = New-Object System.Windows.Controls.Border
  $box.Background = Brush $theme.Bg2; $box.BorderBrush = Brush $theme.Line; $box.BorderThickness = 1
  $box.CornerRadius = [System.Windows.CornerRadius]::new($style.Radius); $box.Padding = '18,14,18,14'; $box.MaxWidth = 380
  $sp = New-Object System.Windows.Controls.StackPanel
  [void]$sp.Children.Add((New-Text $title $theme.Bright 14 'SemiBold'))
  $msg = New-Text $text $theme.Text 12; $msg.TextWrapping = 'Wrap'; $msg.Margin = '0,6,0,14'
  [void]$sp.Children.Add($msg)
  $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'
  $no = New-Object System.Windows.Controls.Button; $no.Content = 'Cancelar'; $no.Style = $window.FindResource('TermBtn'); $no.IsCancel = $true; $no.Margin = '0,0,8,0'
  $yes = New-Object System.Windows.Controls.Button; $yes.Content = $okText; $yes.Style = $window.FindResource('TermBtn'); $yes.Foreground = Brush $crit
  $yes.Add_Click({ $dlg.DialogResult = $true }.GetNewClosure())
  [void]$row.Children.Add($no); [void]$row.Children.Add($yes)
  [void]$sp.Children.Add($row)
  $box.Child = $sp; $dlg.Content = $box
  $dlg.Add_ContentRendered({ $no.Focus() | Out-Null }.GetNewClosure())
  $dlg.Add_MouseLeftButtonDown({ try { $dlg.DragMove() } catch {} }.GetNewClosure())
  [bool]$dlg.ShowDialog()
}

# Cerrar una tarea: su pestaña de Windows Terminal (o su ventana de consola) y todo lo que cuelga de ella
$shellNames = 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'bash.exe', 'sh.exe', 'zsh.exe', 'nu.exe', 'wsl.exe'
function Close-Session($item) {
  $p = [int]$item['Pid']
  $name = [string]$item['Title']
  if (-not (Confirm-Dialog 'Cerrar tarea' "Se cerrará la terminal de «$name» y Claude dejará lo que esté haciendo. ¿Seguro?" 'Cerrar tarea')) { return }
  if ($paused.ContainsKey($p)) { foreach ($id in @($paused[$p].pids)) { [void][TaskMon.Native]::Resume([int]$id) }; $paused.Remove($p); Save-Paused }
  $t = Find-Terminal $item
  # La raíz es la shell que abrió la terminal (la de más arriba de la cadena), para que la pestaña o ventana se cierre sola
  $tree = New-Object TaskMon.Tree (, [TaskMon.Native]::Snapshot())
  $root = $p; $x = $tree.ById[$p]
  for ($i = 0; $i -lt 8 -and $x; $i++) {
    $up = $tree.ById[$x.Ppid]
    if (-not $up -or $up.Name -notin $shellNames) { break }
    $root = $up.Pid; $x = $up
  }
  $closedTab = $false
  if ($t.Tab) {
    $AE = [System.Windows.Automation.AutomationElement]
    $btn = $t.Tab.FindFirst('Descendants', (New-Object System.Windows.Automation.PropertyCondition $AE::AutomationIdProperty, 'CloseButton'))
    if ($btn) { try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $closedTab = $true } catch {} }
  }
  & taskkill.exe /PID $root /T /F 2>&1 | Out-Null
  Log "✕ tarea cerrada: $name$(if ($closedTab) { ' · su pestaña de Windows Terminal' } else { ' · su terminal' })" $crit
  Refresh
}
# Un clic lleva a la terminal; se espera un momento por si es un doble clic (renombrar)
$clickItem = $null
$clickTimer = New-Object System.Windows.Threading.DispatcherTimer
$clickTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$clickTimer.Add_Tick({ $clickTimer.Stop(); $it = $script:clickItem; $script:clickItem = $null; if ($it -and -not $script:editing) { Focus-Session $it } })

$editing = $null
function Find-TitleBox($item) {
  Find-InCard $item 'TitleBox'
}
function Start-Rename($item) {
  if ($script:editing) { Commit-Rename $true }
  $script:editing = $item
  $item['TitleVis'] = 'Collapsed'; $item['EditVis'] = 'Visible'
  $window.Activate() | Out-Null
  $window.Dispatcher.BeginInvoke([Action]{
    $tb = Find-TitleBox $script:editing
    if ($tb) { $tb.Text = [string]$script:editing['Title']; $tb.Focus() | Out-Null; [System.Windows.Input.Keyboard]::Focus($tb) | Out-Null; $tb.SelectAll() }
  }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}
function Commit-Rename([bool]$save) {
  $item = $script:editing
  if (-not $item) { return }
  $script:editing = $null
  if ($save) {
    $tb = Find-TitleBox $item
    $name = if ($tb) { $tb.Text.Trim() } else { '' }
    if ($name -and $name -ne $item['AutoTitle']) {
      Set-Meta $item 'name' $name
      Log "✎ sesión renombrada: $name" $theme.Accent2
    } else {
      Set-Meta $item 'name' $null
    }
  }
  $item['TitleVis'] = 'Visible'; $item['EditVis'] = 'Collapsed'
  Refresh
}

# --- Menú contextual ---------------------------------------------------------------
# Iconos de Segoe (todos del mismo ancho) y texto en fuente proporcional: sin huecos raros entre palabras.
$iconFont = [System.Windows.Media.FontFamily]::new('Segoe Fluent Icons, Segoe MDL2 Assets')
$menuFont = [System.Windows.Media.FontFamily]::new('Segoe UI Variable Text, Segoe UI')
$icons = @{ close = 0xE711; focus = 0xE8A7; rename = 0xE8AC; resetname = 0xE7A7; pause = 0xE769; resume = 0xE768; pin = 0xE718; unpin = 0xE77A; folder = 0xE838; cwdfolder = 0xE838; copypath = 0xE8C8; copyresume = 0xE8C8
  'r-pause' = 0xE769; 'r-resume' = 0xE768; 'r-folder' = 0xE838; 'r-root' = 0xE8B7; 'r-play' = 0xE714; 'r-copy' = 0xE8C8; 'r-session' = 0xE8A7
  'r-chan-nefralis' = 0xE8B9; 'r-chan-solrak' = 0xE8B9; 'r-chan-mrowl' = 0xE8B9; 'r-chan-auto' = 0xE72C; 'r-hide' = 0xE894; 'r-cancel' = 0xE711
  'x-qlaunch' = 0xE768; 'x-qpause' = 0xE769; 'x-qresume' = 0xE768; 'x-qstop' = 0xE71A; 'x-qremove' = 0xE711; 'x-qfront' = 0xE74A; 'x-copycmd' = 0xE8C8; 'x-videodir' = 0xE8B7; 'x-entregado' = 0xE8A5; 'o-close' = 0xE711; 'o-kill' = 0xE7BA; 'o-folder' = 0xE838; 'o-copy' = 0xE8C8 }
$onMenu = {
  param($sender, $e)
  $action = $sender.Tag.Action; $item = $sender.Tag.Item
  switch ($action) {
    'focus' { Focus-Session $item }
    'close' { Close-Session $item }
    'rename' { Start-Rename $item }
    'resetname' { Set-Meta $item 'name' $null; Log "↺ nombre restablecido: $($item['AutoTitle'])" $theme.Accent2; Refresh }
    'pause' { Pause-Session $item }
    'resume' { Resume-Session $item }
    'pin' { Set-Meta $item 'pinned' $true; Refresh }
    'unpin' { Set-Meta $item 'pinned' $null; Refresh }
    'folder' { Start-Process explorer.exe -ArgumentList "`"$($item['StartDir'])`"" }
    'cwdfolder' { Start-Process explorer.exe -ArgumentList "`"$($item['Cwd'])`"" }
    'copyresume' { [System.Windows.Clipboard]::SetText("claude --resume $($item['SessionId'])"); Log "⧉ copiado: claude --resume $($item['SessionId'])" $theme.Accent2 }
    'copypath' { [System.Windows.Clipboard]::SetText([string]$item['StartDir']); Log "⧉ ruta copiada: $($item['StartDir'])" $theme.Accent2 }
    'r-pause' { Pause-Render $item }
    'r-resume' { Resume-Render $item }
    'r-cancel' { Cancel-Render $item }
    'r-folder' { Open-RenderFolder $item }
    'r-root' { Start-Process explorer.exe -ArgumentList "`"$($item['Root'])`"" }
    'r-play' { Start-Process -FilePath ([string]$item['Output']) }
    'r-copy' { [System.Windows.Clipboard]::SetText([string]$item['Output']); Log "⧉ ruta copiada: $($item['Output'])" $theme.Accent2 }
    'r-session' { $s = $itemsByPid.Values | Where-Object { $_['SessionId'] -eq $item['Session'] } | Select-Object -First 1; if ($s) { Focus-Session $s } }
    'r-hide' { $renderStore.hidden[[string]$item['Id']] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); Save-Renders; Refresh }
    { $_ -like 'x-*' -or $_ -like 'o-*' } { Extra-Action $action $item }
    { $_ -like 'r-chan-*' } { Set-RenderChannel $item ($action.Substring(7)) }
  }
}
function New-Text([string]$text, $color, [double]$size = 12, [string]$weight = 'Normal') {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text; $tb.Foreground = $color; $tb.FontSize = $size; $tb.FontWeight = $weight; $tb.FontFamily = $menuFont
  $tb.VerticalAlignment = 'Center'
  $tb
}
function Menu-Entry($menu, [string]$header, [string]$action, $item) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Style = $window.FindResource('TermMenuItem')
  $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'
  $ic = New-Object System.Windows.Controls.TextBlock
  $ic.Text = [string][char]$icons[$action]; $ic.FontFamily = $iconFont; $ic.FontSize = 13; $ic.Width = 26; $ic.VerticalAlignment = 'Center'
  $lb = New-Object System.Windows.Controls.TextBlock
  $lb.Text = $header; $lb.FontFamily = $menuFont; $lb.VerticalAlignment = 'Center'
  [void]$row.Children.Add($ic); [void]$row.Children.Add($lb)
  $mi.Header = $row
  $mi.Tag = @{ Action = $action; Item = $item }
  $mi.Add_Click($onMenu)
  [void]$menu.Items.Add($mi)
}
function Menu-Static($menu, $content) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Style = $window.FindResource('TermMenuStatic')
  $mi.Header = $content
  [void]$menu.Items.Add($mi)
}
function Menu-Separator($menu) {
  $sep = New-Object System.Windows.Controls.Border
  $sep.Height = 1; $sep.Margin = '0,4'; $sep.Background = $theme.Line
  Menu-Static $menu $sep
}
# Cabecera del menú: nombre, estado con su color y desde cuándo, carpetas y en qué está
function Menu-Info($menu, $item) {
  $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '14,6,14,6'; $sp.MaxWidth = 380
  $title = New-Text ([string]$item['Title']) $theme.Bright 13.5 'SemiBold'; $title.TextTrimming = 'CharacterEllipsis'
  [void]$sp.Children.Add($title)

  $state = [string]$item['State']
  $chip = New-Object System.Windows.Controls.StackPanel; $chip.Orientation = 'Horizontal'; $chip.Margin = '0,4,0,8'
  $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = $item['StateColor']; $dot.Margin = '0,0,7,0'; $dot.VerticalAlignment = 'Center'
  [void]$chip.Children.Add($dot)
  [void]$chip.Children.Add((New-Text $stateInfo[$state].Label $item['StateColor'] 11.5 'Bold'))
  if ($item['StateDetail']) { [void]$chip.Children.Add((New-Text " · $($item['StateDetail'])" $theme.Soft 11.5)) }
  [void]$sp.Children.Add($chip)

  $rows = New-Object System.Collections.Generic.List[object]
  $rows.Add(@('Carpeta', $(if ($item['StartDir']) { $item['StartDir'] } else { 'desconocida' })))
  if ($item['Cwd'] -and $item['StartDir'] -and $item['Cwd'].TrimEnd('\') -ne $item['StartDir'].TrimEnd('\')) { $rows.Add(@('Ahora en', $item['Cwd'])) }
  if ($item['LastPrompt']) { $rows.Add(@('Tarea', $item['LastPrompt'])) }
  $rows.Add(@('Recursos', $item['Resources']))
  if ($item['Agents']) { $rows.Add(@('Subagentes', "$($item['Agents']) trabajando")) }
  $grid = New-Object System.Windows.Controls.Grid
  $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
  $c1 = New-Object System.Windows.Controls.ColumnDefinition
  $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1)
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $k = New-Text $rows[$i][0] $theme.Dim 11.5; $k.Margin = '0,1,12,1'; $k.VerticalAlignment = 'Top'
    $v = New-Text ([string]$rows[$i][1]) $theme.Text 11.5; $v.Margin = '0,1,0,1'; $v.TextWrapping = 'Wrap'; $v.MaxHeight = 34; $v.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetRow($k, $i); [System.Windows.Controls.Grid]::SetRow($v, $i); [System.Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$grid.Children.Add($k); [void]$grid.Children.Add($v)
  }
  [void]$sp.Children.Add($grid)
  Menu-Static $menu $sp
}
$onCardMenu = [System.Windows.Input.MouseButtonEventHandler]{
  param($sender, $e)
  $item = $e.OriginalSource.DataContext
  if ($item -isnot [TaskMon.Card]) { return }
  $e.Handled = $true
  $menu = New-Object System.Windows.Controls.ContextMenu
  foreach ($k in $theme.Keys) { if ($k -ne 'Name') { $menu.Resources[$k] = [System.Windows.Media.Brush](Brush $theme[$k]) } }
  $menu.Resources['Radius'] = [System.Windows.CornerRadius]::new($style.Radius)
  $menu.Style = $window.FindResource('TermMenu')
  Menu-Info $menu $item
  Menu-Separator $menu
  Menu-Entry $menu 'Ir a su terminal' 'focus' $item
  Menu-Entry $menu 'Renombrar' 'rename' $item
  if (Get-Meta $item 'name') { Menu-Entry $menu 'Volver al título de la ventana' 'resetname' $item }
  if ($paused.ContainsKey([int]$item['Pid'])) { Menu-Entry $menu 'Reanudar' 'resume' $item } else { Menu-Entry $menu 'Pausar y liberar su RAM' 'pause' $item }
  if (Get-Meta $item 'pinned') { Menu-Entry $menu 'Desfijar' 'unpin' $item } else { Menu-Entry $menu 'Fijar arriba' 'pin' $item }
  Menu-Separator $menu
  if ($item['StartDir']) {
    Menu-Entry $menu 'Abrir carpeta' 'folder' $item
    if ($item['Cwd'] -and $item['Cwd'].TrimEnd('\') -ne $item['StartDir'].TrimEnd('\')) { Menu-Entry $menu 'Abrir carpeta actual' 'cwdfolder' $item }
    Menu-Entry $menu 'Copiar ruta' 'copypath' $item
  }
  if ($item['SessionId']) { Menu-Entry $menu 'Copiar comando para reanudar' 'copyresume' $item }
  Menu-Separator $menu
  Menu-Entry $menu 'Cerrar tarea' 'close' $item
  $menu.PlacementTarget = $e.OriginalSource
  $menu.Placement = 'MousePoint'
  $menu.IsOpen = $true
  $script:lastMenu = $menu
}
foreach ($list in @($ui.TaskGroups)) {
  $list.AddHandler([System.Windows.UIElement]::PreviewMouseRightButtonUpEvent, $onCardMenu)
  $list.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent, [System.Windows.Input.MouseButtonEventHandler]{
    param($sender, $e)
    if ($e.ClickCount -eq 2) {
      $clickTimer.Stop(); $script:clickItem = $null
      if ($e.OriginalSource.Name -eq 'TitleText') { Start-Rename $e.OriginalSource.DataContext; $e.Handled = $true }
    } elseif ($e.ClickCount -eq 1 -and $e.OriginalSource.DataContext -is [TaskMon.Card] -and -not $script:editing -and $e.OriginalSource.Name -ne 'TitleBox') {
      $script:clickItem = $e.OriginalSource.DataContext; $clickTimer.Stop(); $clickTimer.Start()
    }
  }, $true)
  $list.AddHandler([System.Windows.UIElement]::KeyDownEvent, [System.Windows.Input.KeyEventHandler]{
    param($sender, $e)
    if ($e.OriginalSource.Name -ne 'TitleBox') { return }
    if ($e.Key -eq 'Return') { Commit-Rename $true; $e.Handled = $true }
    elseif ($e.Key -eq 'Escape') { Commit-Rename $false; $e.Handled = $true }
  })
  $list.AddHandler([System.Windows.UIElement]::LostKeyboardFocusEvent, [System.Windows.Input.KeyboardFocusChangedEventHandler]{
    param($sender, $e)
    if ($e.OriginalSource.Name -eq 'TitleBox' -and $script:editing) { Commit-Rename $true }
  })
}

# --- Barra de título y ajustes -------------------------------------------------------
$ui.CloseBtn.Add_Click({ $window.Close() })
$ui.MinBtn.Add_Click({ $window.WindowState = 'Minimized' })
$onSettings = {
  $open = [bool]$ui.SettingsBtn.IsChecked
  $ui.SettingsPanel.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
  $ui.TitleCmd.Text = $(if ($open) { 'config --edit' } else { 'watch' })
  Apply-Sprites
}
$ui.SettingsBtn.Add_Checked($onSettings); $ui.SettingsBtn.Add_Unchecked($onSettings)
$ui.SettingsBtn.Add_Checked({ $ui.DiaryBtn.IsChecked = $false; $ui.StageBtn.IsChecked = $false })

# --- Diario ---------------------------------------------------------------------
$projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
# v2: lee también lo pegado, los comandos y las capturas; la caché vieja se descarta para releerlo
$diaryCacheFile = Join-Path $dataDir 'diary-cache-2.json'
Remove-Item -LiteralPath (Join-Path $dataDir 'diary-cache.json') -Force
$diaryTask = $null
$diaryAll = @()
$diaryExpanded = @{}   # sesión|día -> abierta en el diario (se conserva al recargar)
$diaryTimer = New-Object System.Windows.Threading.DispatcherTimer
$diaryTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$diaryTimer.Add_Tick({
  if (-not $script:diaryTask -or -not $script:diaryTask.IsCompleted) { return }
  $diaryTimer.Stop()
  $script:diaryAll = if ($script:diaryTask.IsFaulted) { @() } else { @($script:diaryTask.Result) }
  $script:diaryTask = $null
  # Si lo cerraste mientras leía, no se enseña: se suelta
  if (-not $ui.DiaryBtn.IsChecked) { Release-Diary; return }
  Show-Diary
})
function Load-Diary {
  if ($script:diaryTask) { return }
  $ui.DiaryNote.Text = 'Leyendo los registros de Claude Code…'
  $script:diaryTask = [TaskMon.Diary]::LoadAsync($projectsDir, $diaryCacheFile, 7)
  $diaryTimer.Start()
}
# Une cada entrada del diario con su sesión abierta (por id o por el título que Claude pone a la pestaña)
function Show-Diary {
  $byTitle = @{}; $byId = @{}; $byDir = @{}
  foreach ($it in $items) {
    if ($it['SessionId']) { $byId[[string]$it['SessionId']] = $it }
    # Las sesiones en pausa no leen su título en cada vuelta: se pregunta ahora
    $w = [string]$it['LastWindow']
    if (-not $w) { $wt = Window-Title ([int]$it['Pid']); if ($wt -and $wt.Text) { $w = $wt.Text; $it['LastWindow'] = $w } }
    if ($w) { $byTitle[$w] = $it }
    $dir = ([string]$it['StartDir']).TrimEnd('').ToLower()
    if ($dir) { if ($byDir.ContainsKey($dir)) { $byDir[$dir] = $null } else { $byDir[$dir] = $it } }
  }
  $used = @{}
  $shown = New-Object System.Collections.Generic.List[object]
  foreach ($d in $script:diaryAll) {
    $dirKey = ([string]$d.Cwd).TrimEnd('').ToLower()
    $it = if ($byId.ContainsKey($d.Id)) { $byId[$d.Id] } elseif ($d.Title -and $byTitle.ContainsKey($d.Title)) { $byTitle[$d.Title] } elseif ($dirKey -and $byDir[$dirKey]) { $byDir[$dirKey] } else { $null }
    # Una sesión abierta solo se empareja con su registro más reciente
    if ($it) { if ($used.ContainsKey([int]$it['Pid'])) { $it = $null } else { $used[[int]$it['Pid']] = $true } }
    $d.Open = [bool]$it
    if ($it) { $d.Color = [string]$it['StateColor']; $d.Title = [string]$it['Title'] } else { $d.Color = '#5F6775' }
    if ($settings.diaryScope -eq 'open' -and -not $d.Open) { continue }
    $shown.Add($d)
  }
  # Por días, del más reciente al más viejo; dentro de cada día, primero las abiertas
  $days = [TaskMon.Diary]::ByDay($shown)
  $first = $null
  foreach ($day in $days) { foreach ($d in $day.Sessions) { if (-not $first) { $first = $d }; $d.IsExpanded = [bool]$diaryExpanded[$d.Key] } }
  if ($first -and -not $diaryExpanded.ContainsValue($true)) { $first.IsExpanded = $true }
  $ui.DiaryList.ItemsSource = $days
  $list = $shown
  $turns = 0; foreach ($d in $list) { $turns += $d.Raw.Count }
  $ui.DiarySummary.Text = "Lo que has pedido cada día y lo que hizo Claude: archivos que editó, comandos y tiempo. $($list.Count) sesiones · $turns peticiones en los últimos 7 días."
  $ui.DiaryEmpty.Visibility = $(if ($list.Count) { 'Collapsed' } else { 'Visible' })
  $ui.DiaryEmpty.Text = $(if ($settings.diaryScope -eq 'open') { 'Ninguna sesión abierta tiene peticiones en los últimos 7 días. Prueba con «Últimos 7 días».' } else { 'No hay actividad de Claude Code en los últimos 7 días.' })
  $ui.DiaryNote.Text = "Actualizado a las $((Get-Date).ToString('HH:mm:ss')) · clic en una sesión para ver o esconder su día a día"
}
$ui.DiaryList.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, [System.Windows.RoutedEventHandler]{ param($s, $e) $d = $e.OriginalSource.DataContext; if ($d -is [TaskMon.DiarySession]) { $script:diaryExpanded[$d.Key] = $true } })
$ui.DiaryList.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, [System.Windows.RoutedEventHandler]{ param($s, $e) $d = $e.OriginalSource.DataContext; if ($d -is [TaskMon.DiarySession]) { $script:diaryExpanded[$d.Key] = $false } })
$onDiary = {
  $open = [bool]$ui.DiaryBtn.IsChecked
  if ($open) { $ui.SettingsBtn.IsChecked = $false; $ui.StageBtn.IsChecked = $false }
  $ui.DiaryPanel.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
  $ui.TitleCmd.Text = $(if ($open) { 'diary' } else { 'watch' })
  if ($open) { Load-Diary } else { Release-Diary }
  Apply-Sprites
}
function Release-Diary {
  if ($script:diaryTask) { return }
  $ui.DiaryList.ItemsSource = $null; $script:diaryAll = @()
  [TaskMon.Diary]::Release()
  Trim-Soon
}
$ui.DiaryBtn.Add_Checked($onDiary); $ui.DiaryBtn.Add_Unchecked($onDiary)
$ui.DiaryDone.Add_Click({ $ui.DiaryBtn.IsChecked = $false })
$ui.SettingsDone.Add_Click({ $ui.SettingsBtn.IsChecked = $false })
$window.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Escape' -and $ui.SettingsBtn.IsChecked -and -not $script:editing) { $ui.SettingsBtn.IsChecked = $false }
  elseif ($e.Key -eq 'Escape' -and $ui.DiaryBtn.IsChecked) { $ui.DiaryBtn.IsChecked = $false }
  elseif ($e.Key -eq 'Escape' -and $ui.StageBtn.IsChecked) { $ui.StageBtn.IsChecked = $false }
})

function Flash-Saved { $ui.SettingsSaved.Text = "✔ Guardado a las $((Get-Date).ToString('HH:mm:ss'))" }
$onOption = {
  param($sender, $e)
  $field = $sender.Tag.Field; $value = $sender.Tag.Value
  if ($settings[$field] -eq $value) { return }
  $settings[$field] = $value
  Save-Settings; Flash-Saved
  switch ($field) {
    { $_ -in 'style', 'theme', 'nefFondo' } { Apply-Style; Log "apariencia: $($style.Name)$(if ($settings.style -eq 'hacker') { " · $($theme.Name)" })" }
    'refreshSec' { $timer.Interval = [TimeSpan]::FromSeconds($value) }
    'openMode' { $ui.RamOpts.IsEnabled = ($value -eq 'ram') }
    'diaryScope' { Show-Diary; return }
    'stage' { Update-Stage $true; return }
  }
  Refresh
}
function Add-Option($panel, [string]$field, $value, $content) {
  $rb = New-Object System.Windows.Controls.RadioButton
  $rb.Style = $window.FindResource('TermRadio')
  $rb.GroupName = $field
  $rb.Content = $content
  $rb.Tag = @{ Field = $field; Value = $value }
  $rb.IsChecked = ($settings[$field] -eq $value)
  $rb.Add_Checked($onOption)
  [void]$panel.Children.Add($rb)
}
function Option-Text([string]$title, [string]$detail) {
  $sp = New-Object System.Windows.Controls.StackPanel
  $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = $title
  $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = $detail; $t2.FontSize = 10; $t2.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Dim')
  [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
  $sp
}
foreach ($k in $styles.Keys) { Add-Option $ui.StyleOpts 'style' $k (Option-Text $styles[$k].Name $styles[$k].Detail) }
Add-Option $ui.OpenOpts 'openMode' 'always' (Option-Text 'Cada vez que se inicia una tarea  (por defecto)' 'se abre (o reaparece si la cerraste) con cada mensaje que envías')
Add-Option $ui.OpenOpts 'openMode' 'session' (Option-Text 'Solo con la primera tarea de cada sesión' 'una vez por sesión de Claude Code')
Add-Option $ui.OpenOpts 'openMode' 'ram' (Option-Text 'Solo cuando la RAM supere un umbral' 'se abre al iniciar una tarea si la memoria está por encima de:')
Add-Option $ui.OpenOpts 'openMode' 'never' (Option-Text 'Nunca automáticamente' 'solo con /monitor')
foreach ($v in 70, 80, 90) { Add-Option $ui.RamOpts 'ramThreshold' $v "$v%" }
# Los umbrales van justo debajo de su opción
([System.Windows.Controls.Panel]$ui.RamOpts.Parent).Children.Remove($ui.RamOpts)
$ui.OpenOpts.Children.Insert(3, $ui.RamOpts)
$ui.RamOpts.IsEnabled = ($settings.openMode -eq 'ram')
foreach ($k in $themes.Keys) {
  $t = $themes[$k]
  $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
  foreach ($c in $t.Accent, $t.Accent2, $t.Panel) {
    $sw = New-Object System.Windows.Controls.Border; $sw.Width = 12; $sw.Height = 12; $sw.Margin = '0,0,3,0'; $sw.Background = $c; $sw.BorderBrush = $t.Line; $sw.BorderThickness = 1
    [void]$sp.Children.Add($sw)
  }
  $label = New-Object System.Windows.Controls.TextBlock; $label.Text = " $($t.Name)"; $label.VerticalAlignment = 'Center'
  [void]$sp.Children.Add($label)
  Add-Option $ui.ThemeOpts 'theme' $k $sp
}
foreach ($v in 1, 2, 5) { Add-Option $ui.RefreshOpts 'refreshSec' $v "$v s" }
Add-Option $ui.GroupOpts 'groupMode' 'pinned' (Option-Text 'Fijadas y el resto  (por defecto)' 'las que fijes arriba, con su subtítulo')
Add-Option $ui.GroupOpts 'groupMode' 'state' (Option-Text 'Por estado' 'te esperan, error, en curso, listas, inactivas, en pausa…; las fijadas primero en cada grupo')
Add-Option $ui.GroupOpts 'groupMode' 'none' (Option-Text 'Sin grupos' 'una sola lista, con las fijadas al principio')
Add-Option $ui.SortOpts 'sortMode' 'opened' (Option-Text 'Orden de apertura  (por defecto)' 'la más antigua primero')
Add-Option $ui.SortOpts 'sortMode' 'recent' (Option-Text 'Último uso' 'la que trabajó más recientemente primero')
Add-Option $ui.SortOpts 'sortMode' 'name' (Option-Text 'Nombre' 'de la A a la Z')
Add-Option $ui.SortOpts 'sortMode' 'memory' (Option-Text 'Memoria' 'la que más RAM usa primero')
Add-Option $ui.DiaryScope 'diaryScope' 'open' 'Sesiones abiertas'
Add-Option $ui.DiaryScope 'diaryScope' 'all' 'Todas las de los últimos 7 días'
foreach ($v in 10, 15, 20, 25) { Add-Option $ui.ReserveOpts 'reservePct' $v "$v%" }

$nefFondos = [ordered]@{
  estatua = 'Estatua'; partenon = 'Partenón'; biblioteca_estoica = 'Biblioteca'; olimpia = 'Olimpia'; mar_egeo = 'Mar Egeo'; amanecer_espartano = 'Esparta'
  estoico_cosmos = 'Cosmos'; angel_caido = 'Ángel caído'; ronin = 'Ronin'; guts = 'Guts'; boxeador_manga = 'Boxeador'; muhammad_ali = 'Ali'
}
foreach ($k in $nefFondos.Keys) {
  $sp = New-Object System.Windows.Controls.StackPanel; $sp.Width = 54
  $fr = New-Object System.Windows.Controls.Border; $fr.CornerRadius = 6; $fr.Width = 48; $fr.Height = 85; $fr.HorizontalAlignment = 'Left'
  $thumb = Asset-Image "thumb-$k.jpg"
  if ($thumb) { $ib = New-Object System.Windows.Media.ImageBrush $thumb; $ib.Stretch = 'UniformToFill'; $fr.Background = $ib }
  $lb = New-Object System.Windows.Controls.TextBlock; $lb.Text = $nefFondos[$k]; $lb.FontSize = 10; $lb.Margin = '0,3,0,0'; $lb.TextTrimming = 'CharacterEllipsis'
  [void]$sp.Children.Add($fr); [void]$sp.Children.Add($lb)
  Add-Option $ui.NefFondoOpts 'nefFondo' $k $sp
}
# Cada bloque de opciones va justo debajo de su estilo


$onCheck = {
  param($sender, $e)
  $field = $sender.Tag
  $settings[$field] = [bool]$sender.IsChecked
  Save-Settings; Flash-Saved
  if ($field -eq 'crt') { Apply-Style }
  if ($field -eq 'sprites') { Apply-Sprites; Refresh }
  if ($field -eq 'fixedSize') { Apply-WindowSize $true; Apply-Dock $true }
  if ($field -eq 'dockTerminal') {
    $ui.FixedChk.IsEnabled = -not $settings.dockTerminal
    if ($settings.dockTerminal) { Apply-Dock $true } else { Apply-Dock $false; Apply-WindowSize $false }
  }
  if ($field -eq 'topmost') { $window.Topmost = $settings.topmost }
}
foreach ($pair in @(@('CrtChk', 'crt'), @('SpritesChk', 'sprites'), @('SoundCritChk', 'soundCritical'), @('SoundDoneChk', 'soundDone'), @('TopChk', 'topmost'), @('FixedChk', 'fixedSize'), @('DockChk', 'dockTerminal'))) {
  $cb = $ui[$pair[0]]; $cb.Tag = $pair[1]; $cb.IsChecked = [bool]$settings[$pair[1]]
  $cb.Add_Checked($onCheck); $cb.Add_Unchecked($onCheck)
}
$window.Topmost = [bool]$settings.topmost
$ui.FixedChk.IsEnabled = -not $settings.dockTerminal

# --- Estado -----------------------------------------------------------------
$items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
# Grupos de la lista: cada uno con su subtítulo y su propia colección; se crean al hacer falta
$groupCtl = [ordered]@{}
$groupOrderSig = ''
function New-Group([string]$key) {
  $head = New-Object System.Windows.Controls.DockPanel; $head.Margin = '0,6,0,6'
  $plate = New-Object System.Windows.Controls.Border; $plate.Style = $window.FindResource('Plate')
  $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'
  $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 7; $dot.Height = 7; $dot.Margin = '0,0,6,0'; $dot.VerticalAlignment = 'Center'
  $tag = New-Object System.Windows.Controls.TextBlock; $tag.FontWeight = 'Bold'; $tag.VerticalAlignment = 'Center'
  $tag.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Soft')
  [void]$row.Children.Add($dot); [void]$row.Children.Add($tag); $plate.Child = $row
  $line = New-Object System.Windows.Shapes.Rectangle; $line.Height = 1; $line.Margin = '8,0,0,0'; $line.VerticalAlignment = 'Center'
  $line.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'GroupLine')
  [void]$head.Children.Add($plate); [void]$head.Children.Add($line)
  $coll = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  $list = New-Object System.Windows.Controls.ItemsControl; $list.ItemTemplate = $window.FindResource('TaskCard'); $list.ItemsSource = $coll
  $panel = New-Object System.Windows.Controls.StackPanel
  [void]$panel.Children.Add($head); [void]$panel.Children.Add($list)
  @{ Panel = $panel; Head = $head; Dot = $dot; Tag = $tag; List = $list; Items = $coll }
}
# Orden de los grupos por estado: primero lo que te necesita
$stateOrder = 'waiting', 'error', 'busy', 'resuming', 'done', 'idle', 'paused', 'unknown'
function Sort-Tasks($list) {
  $list = @($list)
  switch ($settings.sortMode) {
    'recent' { @($list | Sort-Object @{ e = { [long]$_['LastUse'] }; Descending = $true }, @{ e = { $_['Created'] } }) }
    'name'   { @($list | Sort-Object @{ e = { [string]$_['Title'] } }) }
    'memory' { @($list | Sort-Object @{ e = { [double]$_['MemMB'] }; Descending = $true }) }
    default  { @($list | Sort-Object @{ e = { $_['Created'] } }) }
  }
}
# Reparte las tarjetas en grupos según el ajuste y devuelve todas en el orden en que se ven
function Update-Groups {
  $sorted = Sort-Tasks $items
  $l = $labels[$settings.style]
  $groups = New-Object System.Collections.Generic.List[object]
  # Fijadas y resto en una sola pasada (sin tuberías: cada vuelta cuenta)
  $pin = New-Object System.Collections.Generic.List[object]; $rest = New-Object System.Collections.Generic.List[object]
  $byState = @{}
  foreach ($it in $sorted) {
    if ($it['Pinned']) { $pin.Add($it) } else { $rest.Add($it) }
    $st = [string]$it['State']
    if (-not $byState.ContainsKey($st)) { $byState[$st] = @{ Pin = New-Object System.Collections.Generic.List[object]; Rest = New-Object System.Collections.Generic.List[object] } }
    if ($it['Pinned']) { $byState[$st].Pin.Add($it) } else { $byState[$st].Rest.Add($it) }
  }
  switch ($settings.groupMode) {
    'state' {
      foreach ($st in $stateOrder) {
        if ($byState.ContainsKey($st)) { $groups.Add(@{ Key = $st; Label = $stateInfo[$st].Label; Color = $stateInfo[$st].Color; Items = [object[]]($byState[$st].Pin.ToArray() + $byState[$st].Rest.ToArray()) }) }
      }
    }
    'none' { $groups.Add(@{ Key = 'all'; Label = ''; Items = [object[]]($pin.ToArray() + $rest.ToArray()) }) }
    default {
      $pin = $pin.ToArray(); $rest = $rest.ToArray()
      if ($pin.Count) { $groups.Add(@{ Key = 'pinned'; Label = $l.Pinned; Star = $true; Items = $pin }) }
      if ($rest.Count) { $groups.Add(@{ Key = 'rest'; Label = $(if ($pin.Count) { $l.Rest } else { '' }); Items = $rest }) }
    }
  }
  $sig = ($groups | ForEach-Object { $_.Key }) -join '|'
  foreach ($g in $groups) {
    if (-not $groupCtl.Contains($g.Key)) { $groupCtl[$g.Key] = New-Group $g.Key }
    $c = $groupCtl[$g.Key]
    Sync-Items $c.Items @($g.Items)
    $c.Head.Visibility = $(if ($g.Label) { 'Visible' } else { 'Collapsed' })
    $c.Tag.Text = Spaced "$(if ($g.Star) { '★ ' })$($g.Label) ($(@($g.Items).Count))"
    $c.Tag.FontSize = $(if ($settings.style -eq 'nefralis') { 11 } else { 10.5 })
    if ($g.Color) { $c.Dot.Fill = Brush-Cached $g.Color; $c.Dot.Visibility = 'Visible' } else { $c.Dot.Visibility = 'Collapsed' }
  }
  # Los grupos que ya no tocan se vacían; el orden de los paneles solo se rehace si cambia
  $present = @{}; foreach ($g in $groups) { $present[$g.Key] = $true }
  foreach ($k in @($groupCtl.Keys)) { if (-not $present.ContainsKey($k)) { $groupCtl[$k].Items.Clear() } }
  if ($sig -ne $script:groupOrderSig) {
    $script:groupOrderSig = $sig
    $ui.TaskGroups.Children.Clear()
    foreach ($g in $groups) { [void]$ui.TaskGroups.Children.Add($groupCtl[$g.Key].Panel) }
  }
  $all = @(); foreach ($g in $groups) { $all += @($g.Items) }
  $all
}
# Deja $coll con los elementos de $want y en su orden, moviendo solo lo necesario
function Sync-Items($coll, $want) {
  $keep = New-Object 'System.Collections.Generic.HashSet[object]'
  foreach ($w in $want) { [void]$keep.Add($w) }
  for ($i = $coll.Count - 1; $i -ge 0; $i--) { if (-not $keep.Contains($coll[$i])) { $coll.RemoveAt($i) } }
  for ($i = 0; $i -lt $want.Count; $i++) {
    $cur = $coll.IndexOf($want[$i])
    if ($cur -lt 0) { $coll.Insert($i, $want[$i]) } elseif ($cur -ne $i) { $coll.Move($cur, $i) }
  }
}
$itemsByPid = @{}
$cpuHistory = New-Object System.Collections.Generic.List[double]
$ramHistory = New-Object System.Collections.Generic.List[double]
$taskMemHistory = @{}
$prevCpu = @{}
$prevTime = $null
$prevStates = $null
$prevRamLevel = 0
$startedAt = Get-Date

# --- Claudes en pixel art: cada tarjeta lleva el suyo, haciendo algo según el estado de su sesión ----
# Lienzo de 30x22 píxeles ampliado x3 sin suavizar. Cada (escena, fotograma) se dibuja una sola vez y se reutiliza.
$pixW = 30; $pixH = 22
$pixFrames = @{}
$glyphs = @{
  ask   = '.###./#...#/..##./...../..#..'
  bang  = '..#../..#../..#../...../..#..'
  check = '....#/...#./#.#../.#.../.....'
  play  = '#.../##../###./##../#...'
  pause = '#.#/#.#/#.#/#.#'
  zed   = '###/.#./###'
  note  = '..##/..#./..#./##../##..'
  cross = '#...#/.#.#./..#../.#.#./#...#'
  plus  = '.#./###/.#.'
  ring  = '.##./#..#/#..#/.##.'
}
# Escenas de cada estado; al entrar en un estado, la sesión coge la menos repetida entre las que están igual
$scenes = [ordered]@{
  busy     = @('portatil', 'obra', 'pizarra', 'laboratorio', 'pintura')
  waiting  = @('mano', 'reloj', 'cartel')
  done     = @('salto', 'trofeo', 'baile')
  idle     = @('dormir', 'cafe', 'pesca')
  paused   = @('hielo', 'estatua', 'nieve')
  resuming = @('temblor', 'deshielo')
  error    = @('humo', 'fuego')
  unknown  = @('duda', 'lupa')
}
$sceneText = @{
  portatil = 'programando en su portátil'; obra = 'en la obra, martillo en mano'; pizarra = 'dando clase en la pizarra'
  laboratorio = 'mezclando pociones en el laboratorio'; pintura = 'pintando un cuadro'
  mano = 'levantando la mano: te necesita'; reloj = 'mirando el reloj mientras te espera'; cartel = 'con un cartel para que le hagas caso'
  salto = 'saltando de alegría'; trofeo = 'levantando su trofeo'; baile = 'bailando la victoria'
  dormir = 'echándose una siesta'; cafe = 'tomándose un café'; pesca = 'pescando tranquilamente'
  hielo = 'congelado en un bloque de hielo'; estatua = 'convertido en estatua'; nieve = 'quieto bajo la nieve'
  temblor = 'sacudiéndose el frío'; deshielo = 'descongelándose'
  humo = 'echando humo'; fuego = 'con el portátil en llamas'
  duda = 'sin datos: ¿quién será?'; lupa = 'buscando pistas'
}
$clawdBody = '#D97757'
function Draw-Clawd($px, [int]$x, [int]$y, [hashtable]$o) {
  $body = if ($o.Body) { $o.Body } else { $clawdBody }
  $shade = if ($o.Shade) { $o.Shade } else { '#B35E44' }
  $eye = '#1B1B1F'
  $px.Rect($x + 1, $y + 9, 10, 1, '#55000000')
  # Patas: con Step=1 se levantan la primera y la tercera (andar)
  foreach ($lx in 2, 4, 7, 9) {
    $short = $o.Step -eq 1 -and $lx -in 2, 7
    $px.Rect($x + $lx, $y + 7, 1, $(if ($short) { 1 } else { 2 }), $shade)
  }
  $px.Rect($x + 2, $y, 8, 7, $body)
  $px.Rect($x + 2, $y + 6, 8, 1, $shade)
  $px.Rect($x + 2, $y, 8, 1, $(if ($o.Top) { $o.Top } else { '#E8957A' }))
  switch ($o.Arms) {
    'up'     { $px.Rect($x, $y, 2, 2, $body); $px.Rect($x + 10, $y, 2, 2, $body) }
    'hold'   { $px.Rect($x + 1, $y - 2, 2, 3, $body); $px.Rect($x + 9, $y - 2, 2, 3, $body) }
    'type0'  { $px.Rect($x, $y + 3, 2, 2, $body); $px.Rect($x + 10, $y + 4, 3, 1, $body) }
    'type1'  { $px.Rect($x, $y + 3, 2, 2, $body); $px.Rect($x + 10, $y + 3, 3, 1, $body) }
    'wave'   { $px.Rect($x, $y + 3, 2, 2, $body); $px.Rect($x + 10, $y + 1, 2, 2, $body) }
    'pointL' { $px.Rect($x - 1, $y + 3, 3, 1, $body); $px.Rect($x + 10, $y + 3, 2, 2, $body) }
    'left'   { $px.Rect($x, $y + 3, 2, 2, $body) }
    default  { $px.Rect($x, $y + 3, 2, 2, $body); $px.Rect($x + 10, $y + 3, 2, 2, $body) }
  }
  switch ($o.Eyes) {
    'look'   { $px.Rect($x + 4, $y + 2, 1, 2, $eye); $px.Rect($x + 8, $y + 2, 1, 2, $eye) }
    'left'   { $px.Rect($x + 3, $y + 2, 1, 2, $eye); $px.Rect($x + 6, $y + 2, 1, 2, $eye) }
    'up'     { $px.Rect($x + 3, $y + 1, 1, 2, $eye); $px.Rect($x + 8, $y + 1, 1, 2, $eye) }
    'wide'   { $px.Rect($x + 3, $y + 1, 2, 2, $eye); $px.Rect($x + 7, $y + 1, 2, 2, $eye) }
    'closed' { $px.Rect($x + 3, $y + 3, 2, 1, $eye); $px.Rect($x + 7, $y + 3, 2, 1, $eye) }
    'happy'  { $px.Glyph($x + 3, $y + 2, '.#./#.#', $eye); $px.Glyph($x + 6, $y + 2, '.#./#.#', $eye) }
    'angry'  { $px.Glyph($x + 3, $y + 2, '#./##', $eye); $px.Glyph($x + 7, $y + 2, '.#/##', $eye) }
    default  { $px.Rect($x + 3, $y + 2, 1, 2, $eye); $px.Rect($x + 8, $y + 2, 1, 2, $eye) }
  }
  switch ($o.Hat) {
    'obra'  { $px.Rect($x + 2, $y - 2, 8, 2, '#FACC15'); $px.Rect($x + 1, $y - 1, 10, 1, '#EAB308'); $px.Dot($x + 4, $y - 2, '#FDE68A') }
    'boina' { $px.Rect($x + 3, $y - 1, 6, 1, '#DC2626'); $px.Rect($x + 4, $y - 2, 4, 1, '#DC2626'); $px.Dot($x + 6, $y - 3, '#DC2626') }
    'gafas' { $px.Rect($x + 2, $y + 2, 8, 1, '#334155'); $px.Rect($x + 3, $y + 1, 3, 3, '#93C5FD'); $px.Rect($x + 7, $y + 1, 3, 3, '#93C5FD'); $px.Dot($x + 4, $y + 2, $eye); $px.Dot($x + 8, $y + 2, $eye) }
    'nieve' { $px.Rect($x + 2, $y - 1, 8, 1, '#F8FAFC'); $px.Rect($x + 2, $y + 5, 8, 1, '#EF4444'); $px.Rect($x + 8, $y + 6, 1, 2, '#EF4444') }
  }
}
function Draw-Bubble($px, [int]$x, [int]$y, [string]$glyph, [string]$color) {
  $px.Rect($x, $y, 9, 7, '#F2F2F2')
  $px.Rect($x + 1, $y + 7, 2, 1, '#F2F2F2'); $px.Dot($x + 1, $y + 8, '#F2F2F2')
  $px.Dot($x, $y, '#00000000')
  if ($glyph) { $px.Glyph($x + 2, $y + 1, $glyphs[$glyph], $color) }
}
# Mezcla dos colores #RRGGBB: t = cuánto del primero
function Mix-Hex([string]$a, [string]$b, [double]$t) {
  $x = [Convert]::ToInt32($a.TrimStart('#').Substring($a.TrimStart('#').Length - 6), 16); $y = [Convert]::ToInt32($b.TrimStart('#').Substring($b.TrimStart('#').Length - 6), 16)
  $out = 0
  foreach ($sh in 16, 8, 0) { $out = $out -bor ([int][Math]::Round((($x -shr $sh) -band 255) * $t + (($y -shr $sh) -band 255) * (1 - $t)) -shl $sh) }
  '#' + $out.ToString('X6')
}
function Draw-Floor($px) { $px.Rect(0, 20, $pixW, 2, '#262A31'); $px.Rect(0, 20, $pixW, 1, '#363B44') }
function Draw-Laptop($px, [int]$x, [int]$y, [string]$screen) {
  $px.Rect($x, $y, 9, 7, '#3A3F4B'); $px.Rect($x + 1, $y + 1, 7, 5, $screen)
  $px.Rect($x - 1, $y + 7, 11, 1, '#8A93A3')
  $px.Rect($x - 1, $y + 8, 11, 3, '#4A3B32'); $px.Rect($x, $y + 8, 9, 1, '#5C4A3E')
}
function Get-PixFrame([string]$scene, [int]$f) {
  $key = "$scene|$f"
  if ($pixFrames.ContainsKey($key)) { return $pixFrames[$key] }
  $px = New-Object TaskMon.Pix $pixW, $pixH
  $state, $name = $scene.Split('|')
  $c = State-Color $state
  # Todo el dibujo va sobre el color de su estado: de un vistazo se sabe qué hace cada uno
  $px.Rect(0, 0, $pixW, $pixH, (Mix-Hex $c '#121418' 0.26))
  $px.Rect(0, 0, $pixW, 6, (Mix-Hex $c '#121418' 0.34))
  if ($name -ne 'pesca') { $px.Rect(0, 20, $pixW, 2, (Mix-Hex $c '#1E2128' 0.5)); $px.Rect(0, 20, $pixW, 1, (Mix-Hex $c '#2A2E36' 0.75)) }
  switch ($name) {
    'portatil' {
      # Escribiendo en su portátil, con líneas de código que avanzan
      Draw-Laptop $px 19 9 '#0F1726'
      for ($i = 0; $i -lt 3; $i++) { $px.Rect(21, 11 + $i, 1 + (($f + $i * 2) % 5), 1, $c) }
      Draw-Clawd $px 5 (10 - ($f % 2)) @{ Arms = "type$($f % 2)"; Eyes = 'look' }
      if ($f -lt 2) { $px.Dot(23 + $f, 7 - $f, $c) }
    }
    'obra' {
      # Levantando un muro con casco y martillo
      $px.Rect(20, 12, 10, 8, '#B4533A')
      for ($r = 0; $r -lt 4; $r++) {
        $px.Rect(20, 13 + $r * 2, 10, 1, '#6E2F22')
        for ($k = 20 + ($r % 2) * 2; $k -lt 30; $k += 4) { $px.Dot($k, 12 + $r * 2, '#6E2F22') }
      }
      $px.Rect(20, 12, 10, 1, '#C9694F')
      Draw-Clawd $px 4 10 @{ Arms = 'left'; Eyes = 'look'; Hat = 'obra' }
      if ($f % 2) {
        $px.Rect(14, 14, 3, 1, $clawdBody); $px.Rect(17, 14, 2, 1, '#8B5A2B'); $px.Rect(18, 12, 2, 4, '#9CA3AF')
        $sparks = if ($f -eq 1) { @(@(21, 10), @(23, 12), @(22, 15)) } else { @(@(22, 11), @(21, 16), @(24, 14)) }
        foreach ($s in $sparks) { $px.Dot($s[0], $s[1], '#FDE047') }
      } else {
        $px.Rect(14, 11, 2, 2, $clawdBody); $px.Rect(15, 6, 1, 5, '#8B5A2B'); $px.Rect(14, 5, 4, 2, '#9CA3AF')
      }
    }
    'pizarra' {
      # Dando clase: la pizarra se va llenando y el puntero señala
      $px.Rect(1, 3, 17, 12, '#6B4F3A'); $px.Rect(2, 4, 15, 10, '#1F4D3A'); $px.Rect(2, 14, 15, 1, '#8B6B4F')
      $lens = 9, 6, 11, 4
      for ($i = 0; $i -lt 4; $i++) { if ($i -le $f) { $px.Rect(4, 6 + $i * 2, $lens[$i], 1, '#E5E7EB') } }
      $px.Glyph(13, 5, '#.#/.#./#.#', '#FDE68A')
      Draw-Clawd $px 17 10 @{ Arms = 'pointL'; Eyes = 'left'; Step = $f % 2 }
      $px.Rect(12, 13 - ($f % 2), 4, 1, '#D6B98C')
    }
    'laboratorio' {
      # Mezclando pociones: el matraz burbujea
      $px.Rect(16, 16, 13, 1, '#8A93A3'); $px.Rect(17, 17, 1, 3, '#6B7280'); $px.Rect(27, 17, 1, 3, '#6B7280')
      $px.Rect(20, 9, 2, 3, '#B0D8E8'); $px.Rect(19, 12, 4, 1, '#B0D8E8'); $px.Rect(18, 13, 6, 3, '#B0D8E8')
      $px.Rect(18, 14, 6, 2, '#4ADE80'); $px.Rect(19, 13, 4, 1, '#86EFAC')
      $px.Dot(20 + ($f % 2), 7 - ($f % 3), '#86EFAC'); $px.Dot(21 - ($f % 2), 4 + ($f % 2), '#4ADE80')
      if ($f -eq 3) { $px.Rect(19, 2, 4, 2, '#6686EFAC') }
      $px.Rect(26, 10, 1, 6, '#B0D8E8'); $px.Rect(26, 12, 1, 4, '#E879F9'); $px.Rect(25, 10, 3, 1, '#9CA3AF')
      Draw-Clawd $px 4 10 @{ Arms = "type$($f % 2)"; Hat = 'gafas' }
    }
    'pintura' {
      # Pintando un paisaje que se completa poco a poco
      $px.Rect(20, 8, 1, 12, '#8B5A2B'); $px.Rect(27, 8, 1, 12, '#8B5A2B'); $px.Rect(19, 16, 10, 1, '#8B5A2B')
      $px.Rect(19, 3, 10, 10, '#F3F4F6')
      $px.Rect(20, 4, 8, 4, '#93C5FD')
      if ($f -ge 1) { $px.Rect(25, 4, 2, 2, '#FACC15') }
      if ($f -ge 2) { $px.Rect(20, 9, 8, 3, '#4ADE80'); $px.Rect(22, 8, 3, 1, '#4ADE80') }
      if ($f -ge 3) { $px.Rect(21, 7, 1, 2, '#B45309'); $px.Rect(20, 6, 3, 1, '#16A34A') }
      Draw-Clawd $px 5 10 @{ Arms = "type$($f % 2)"; Eyes = 'look'; Hat = 'boina' }
      $px.Dot(18, 13 + ($f % 2) - 1, @('#93C5FD', '#FACC15', '#4ADE80', '#B45309')[$f])
      $px.Rect(3, 14, 3, 2, '#D6B98C'); $px.Dot(3, 14, '#EF4444'); $px.Dot(5, 14, '#3B82F6')
    }
    'mano' {
      Draw-Clawd $px 9 (10 - ($f % 2)) @{ Arms = $(if ($f % 2) { 'wave' } else { 'side' }); Eyes = 'up'; Step = $f % 2 }
      Draw-Bubble $px 19 1 'ask' $c
    }
    'reloj' {
      # Mirando el reloj y dando golpecitos con el pie
      Draw-Clawd $px 9 10 @{ Arms = 'wave'; Eyes = 'up'; Step = $f % 2 }
      $px.Dot(20, 11, '#FACC15')
      Draw-Bubble $px 19 1 '' $c
      for ($i = 0; $i -le ($f % 3); $i++) { $px.Dot(21 + $i * 2, 4, $c) }
    }
    'cartel' {
      # Con un cartel en alto para que le veas
      $b = $f % 2
      $px.Rect(8, 1 + $b, 14, 6, '#F2F2F2'); $px.Rect(8, 7 + $b, 14, 1, '#C8CCD2')
      $px.Glyph(13, 2 + $b, $glyphs.ask, $c)
      Draw-Clawd $px 9 10 @{ Arms = 'hold'; Eyes = 'up'; Step = $b }
    }
    'salto' {
      $jump = if ($f -eq 1) { 2 } else { 0 }
      Draw-Clawd $px 9 (10 - $jump) @{ Arms = $(if ($f -le 1) { 'up' } else { 'side' }); Eyes = 'happy' }
      Draw-Bubble $px 19 1 'check' $c
      foreach ($p in @(@(4, 3, '#FACC15'), @(7, 1, '#4D9BFF'), @(25, 12, '#E879F9'), @(3, 9, '#2ED47A'))) { if (($f + $p[0]) % 2) { $px.Dot($p[0], $p[1] + ($f % 2), $p[2]) } }
    }
    'trofeo' {
      # Levantando la copa entre destellos
      $y = 11 - $(if ($f -eq 1) { 1 } else { 0 })
      $px.Rect(12, $y - 8, 6, 3, '#FACC15'); $px.Rect(13, $y - 5, 4, 1, '#FACC15'); $px.Dot(11, $y - 7, '#EAB308'); $px.Dot(18, $y - 7, '#EAB308')
      $px.Rect(14, $y - 4, 2, 1, '#CA8A04'); $px.Rect(13, $y - 3, 4, 1, '#CA8A04'); $px.Dot(13, $y - 7, '#FEF9C3')
      Draw-Clawd $px 9 $y @{ Arms = 'hold'; Eyes = 'happy' }
      $spark = if ($f % 2) { @(@(3, 4), @(24, 9)) } else { @(@(24, 2), @(5, 11)) }
      foreach ($s in $spark) { $px.Glyph($s[0], $s[1], $glyphs.plus, '#FDE68A') }
    }
    'baile' {
      # Bailando sobre una pista de colores
      for ($i = 0; $i -lt 6; $i++) { $px.Rect($i * 5, 20, 5, 2, $(if (($i + $f) % 2) { '#3B2F5C' } else { '#22304A' })) }
      $dx = @(0, 1, 0, -1)[$f]
      Draw-Clawd $px (9 + $dx) (10 - ($f % 2)) @{ Arms = $(if ($f % 2) { 'up' } else { 'wave' }); Eyes = 'happy'; Step = $f % 2 }
      $nc = @('#4D9BFF', '#E879F9', '#FACC15', '#2ED47A')
      $px.Glyph(23, 3 + ($f % 2), $glyphs.note, $nc[$f]); $px.Glyph(3, 5 - ($f % 2), $glyphs.note, $nc[($f + 2) % 4])
    }
    'dormir' {
      Draw-Clawd $px 9 10 @{ Eyes = 'closed'; Body = '#A9644F'; Shade = '#87503F'; Top = '#B97560' }
      $px.Glyph(21 + ($f % 2), 7 - $f, $glyphs.zed, '#AEB6C4')
      if ($f -ge 2) { $px.Dot(25, 3 - ($f - 2), '#AEB6C4') }
    }
    'cafe' {
      # Un café tranquilo junto a la planta
      Draw-Clawd $px 6 10 @{ Arms = 'left'; Eyes = 'closed' }
      $px.Rect(16, 14, 2, 1, $clawdBody)
      $px.Rect(18, 12, 3, 4, '#E5E7EB'); $px.Rect(18, 12, 3, 1, '#7C4A2D'); $px.Dot(21, 13, '#E5E7EB'); $px.Dot(21, 14, '#E5E7EB')
      $px.Dot(19 + ($f % 2), 10, '#9CA3AF'); $px.Dot(20 - ($f % 2), 8, '#9CA3AF'); $px.Dot(19 + (($f + 1) % 2), 6, '#6B7280')
      $px.Rect(25, 16, 3, 4, '#B45309'); $px.Rect(24, 12, 2, 4, '#22C55E'); $px.Rect(27, 11, 2, 5, '#16A34A'); $px.Dot(26, 13 - ($f % 2), '#4ADE80')
    }
    'pesca' {
      # Pescando desde el muelle; el corcho sube y baja
      $px.Rect(0, 19, 17, 3, '#6B4A2B'); $px.Rect(0, 19, 17, 1, '#8B6238'); $px.Dot(5, 20, '#4A3320'); $px.Dot(11, 21, '#4A3320')
      $px.Rect(17, 18, 13, 4, '#1E3A5F')
      $px.Rect(18 + ($f % 2) * 2, 18, 2, 1, '#3B82F6'); $px.Rect(25 - ($f % 2) * 2, 19, 2, 1, '#2563EB')
      Draw-Clawd $px 3 10 @{ Arms = 'left'; Eyes = 'closed' }
      $px.Rect(13, 13, 2, 1, $clawdBody)
      for ($k = 0; $k -lt 7; $k++) { $px.Dot(15 + $k, 13 - $k, '#A16207') }
      $px.Rect(22, 7, 1, 10 + ($f % 2), '#9CA3AF'); $px.Dot(22, 17 + ($f % 2), '#EF4444')
    }
    'hielo' {
      Draw-Clawd $px 9 10 @{ Eyes = 'closed'; Body = '#C2A79D'; Shade = '#9C857C'; Top = '#D2BAB0' }
      $px.Rect(7, 8, 16, 12, '#5579D4F0'); $px.Rect(7, 8, 16, 1, '#CCB8EEFA'); $px.Rect(7, 8, 1, 12, '#99B8EEFA')
      $px.Dot(9 + ($f * 3) % 12, 9, '#FFFFFFFF')
      Draw-Bubble $px 20 1 'pause' $c
    }
    'estatua' {
      # Convertido en estatua de piedra sobre su pedestal
      $px.Rect(6, 16, 18, 1, '#D1D5DB'); $px.Rect(7, 17, 16, 3, '#9CA3AF'); $px.Rect(8, 18, 14, 1, '#8B9099')
      Draw-Clawd $px 9 7 @{ Eyes = 'closed'; Body = '#B8B2AA'; Shade = '#8E8880'; Top = '#D6D1CA' }
      $px.Dot(11 + ($f * 2) % 8, 8, '#F5F5F4')
      Draw-Bubble $px 20 1 'pause' $c
    }
    'nieve' {
      # Quieto bajo la nieve, con bufanda
      $px.Rect(0, 20, $pixW, 1, '#E2E8F0')
      Draw-Clawd $px 9 10 @{ Eyes = 'closed'; Body = '#BFD4E6'; Shade = '#93AFC6'; Top = '#DCE8F2'; Hat = 'nieve' }
      for ($k = 0; $k -lt 10; $k++) { $px.Dot(($k * 7 + 2) % 30, ($k * 5 + $f * 2) % 19, '#E2E8F0') }
    }
    'temblor' {
      Draw-Clawd $px (9 + $(if ($f % 2) { 1 } else { -1 })) 10 @{ Eyes = 'open'; Step = $f % 2 }
      Draw-Bubble $px 20 1 'play' $c
    }
    'deshielo' {
      # El hielo se derrite y deja un charco
      $px.Rect(4, 20, 22, 1, '#79D4F0')
      Draw-Clawd $px 9 10 @{ Eyes = 'open'; Body = '#CC9A88'; Shade = '#A87C6C' }
      $h = 7 - $f * 2
      if ($h -gt 0) { $px.Rect(7, 20 - $h, 16, $h, '#5579D4F0'); $px.Rect(7, 20 - $h, 16, 1, '#99B8EEFA') }
      $px.Dot(10 + ($f * 4) % 12, 12 + $f, '#79D4F0'); $px.Dot(19 - ($f * 3) % 9, 13 + ($f % 2), '#79D4F0')
      Draw-Bubble $px 20 1 'play' $c
    }
    'humo' {
      Draw-Clawd $px 9 10 @{ Eyes = 'angry'; Body = '#E0605A'; Shade = '#B34843'; Top = '#EA7C76' }
      Draw-Bubble $px 20 1 'bang' $c
      $px.Rect(12 + ($f % 2), 7 - $f, 2, 1, '#6B7280'); $px.Rect(15, 6 - ($f % 3), 1, 1, '#6B7280')
    }
    'fuego' {
      # El portátil arde y Claude no sabe qué hacer
      Draw-Laptop $px 19 9 '#7F1D1D'
      $px.Glyph(21, 10, $glyphs.cross, '#FCA5A5')
      $hs = 3, 5, 2, 4, 6, 3, 4, 5, 2
      for ($i = 0; $i -lt 9; $i++) {
        $hh = $hs[($i + $f * 2) % 9]
        $px.Rect(19 + $i, 9 - $hh, 1, $hh, '#F97316')
        if ($hh -ge 4) { $px.Rect(19 + $i, 10 - [int]($hh / 2), 1, [int]($hh / 2) - 1, '#FACC15') }
      }
      Draw-Clawd $px 3 (10 - ($f % 2)) @{ Arms = 'up'; Eyes = 'wide'; Step = $f % 2 }
      if ($f % 2) { $px.Dot(3, 8, '#7DD3FC') }
    }
    'lupa' {
      # Buscando pistas con la lupa
      $x = 6 + @(0, 1, 2, 1)[$f]
      Draw-Clawd $px $x 10 @{ Eyes = 'look'; Body = '#8C939E'; Shade = '#6E757F'; Top = '#A3A9B2'; Step = $f % 2 }
      $px.Rect($x + 14, 11, 2, 2, '#5593C5FD'); $px.Glyph($x + 13, 10, $glyphs.ring, '#D1D5DB'); $px.Dot($x + 12, 14, '#A16207')
      $px.Glyph(3, 2, $glyphs.ask, '#6B7280')
    }
    default {
      Draw-Clawd $px 9 10 @{ Eyes = 'open'; Body = '#8C939E'; Shade = '#6E757F'; Top = '#A3A9B2' }
      Draw-Bubble $px 20 1 'ask' $c
    }
  }
  $bmp = $px.ToBitmap()
  $pixFrames[$key] = $bmp
  $bmp
}

# Cada sesión toma una escena al entrar en un estado: la menos repetida entre las que están igual
$sceneOf = @{}     # pid -> 'estado|escena'
$spriteImg = @{}   # pid -> Image de su tarjeta
function Pick-Scenes {
  foreach ($it in $items) {
    $p = [int]$it['Pid']; $st = [string]$it['State']
    $cur = $sceneOf[$p]
    if ($cur -and $cur.StartsWith("$st|")) { continue }
    $list = $scenes[$st]; if (-not $list) { $list = $scenes['unknown']; $st = 'unknown' }
    $used = @{}; foreach ($v in @($sceneOf.Values)) { $used[$v] = 1 + [int]$used[$v] }
    $start = Get-Random -Maximum $list.Count
    $best = $null
    for ($j = 0; $j -lt $list.Count; $j++) {
      $cand = "$st|$($list[($start + $j) % $list.Count])"
      if (-not $best -or [int]$used[$cand] -lt [int]$used[$best]) { $best = $cand }
    }
    $sceneOf[$p] = $best
    $it['SceneTip'] = "Claude está $($sceneText[$best.Split('|')[1]])"
  }
}
function Find-InCard($item, [string]$name) {
  foreach ($g in $groupCtl.Values) {
    $cp = $g.List.ItemContainerGenerator.ContainerFromItem($item)
    if ($cp) { $cp.ApplyTemplate() | Out-Null; $el = $cp.ContentTemplate.FindName($name, $cp); if ($el) { return $el } }
  }
}
$sceneFrames = @{}  # escena -> sus 4 fotogramas
$animator = New-Object TaskMon.Animator ([System.Windows.Controls.Image]::SourceProperty), 300
function Update-Sprites {
  if (-not $settings.sprites) { return }
  foreach ($item in $items) {
    $p = [int]$item['Pid']
    $scene = $sceneOf[$p]; if (-not $scene) { continue }
    $img = $spriteImg[$p]
    if (-not $img -or -not [object]::ReferenceEquals($img.DataContext, $item)) {
      $img = Find-InCard $item 'Sprite'; if (-not $img) { continue }
      $spriteImg[$p] = $img
    }
    $frames = $sceneFrames[$scene]
    if (-not $frames) {
      $frames = [System.Windows.Media.Imaging.BitmapSource[]]@(0..3 | ForEach-Object { Get-PixFrame $scene $_ })
      $sceneFrames[$scene] = $frames
    }
    # Los que descansan van a medio ritmo
    [void]$animator.Set($p, $img, $frames, ($scene -match '^(idle|paused)'))
  }
}
# Solo se anima con la ventana a la vista y los ajustes cerrados
function Apply-Sprites {
  $window.Resources['SpriteVis'] = [System.Windows.Visibility]$(if ($settings.sprites) { 'Visible' } else { 'Collapsed' })
  if ($settings.sprites -and $window.WindowState -ne 'Minimized' -and -not $ui.SettingsBtn.IsChecked -and -not $ui.DiaryBtn.IsChecked -and -not $ui.StageBtn.IsChecked) { $animator.Start() } else { $animator.Stop() }
  if ($ui.StageBtn.IsChecked -and $window.WindowState -ne 'Minimized') { $stage.Start() } else { $stage.Stop() }
}
$window.Resources['SpriteVis'] = [System.Windows.Visibility]$(if ($settings.sprites) { 'Visible' } else { 'Collapsed' })

# Galería: una ventanita con todas las animaciones de las tarjetas, agrupadas por estado
function Show-Gallery {
  $t = $script:theme
  $dlg = New-Object System.Windows.Window
  $dlg.Title = 'Animaciones de Claude'; $dlg.Width = 500; $dlg.Height = 640; $dlg.Owner = $window
  $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.ResizeMode = 'CanResize'; $dlg.ShowInTaskbar = $false
  $dlg.Background = Brush $t.Bg; $dlg.FontFamily = $menuFont
  $root = New-Object System.Windows.Controls.DockPanel; $root.Background = Brush $t.Bg
  $head = New-Object System.Windows.Controls.StackPanel; $head.Margin = '16,14,16,6'
  [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
  $h1 = New-Object System.Windows.Controls.TextBlock; $h1.Text = 'Animaciones de Claude'; $h1.FontSize = 18; $h1.FontWeight = 'Bold'; $h1.Foreground = Brush $t.Bright
  $h2 = New-Object System.Windows.Controls.TextBlock; $h2.Text = 'Lo que hace el Claude de cada tarjeta según el estado de su sesión. Al entrar en un estado, cada sesión coge la escena menos repetida.'; $h2.TextWrapping = 'Wrap'; $h2.FontSize = 11; $h2.Foreground = Brush $t.Dim; $h2.Margin = '0,3,0,0'
  [void]$head.Children.Add($h1); [void]$head.Children.Add($h2); [void]$root.Children.Add($head)
  $sv = New-Object System.Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility = 'Auto'; $sv.Padding = '12,0,12,12'
  $list = New-Object System.Windows.Controls.StackPanel
  $anim = New-Object TaskMon.Animator ([System.Windows.Controls.Image]::SourceProperty), 300
  $key = 0
  foreach ($st in 'busy', 'waiting', 'done', 'idle', 'paused', 'resuming', 'error', 'unknown') {
    $info = $stateInfo[$st]; $c = $info.Color
    # Subtítulo del estado con su color
    $sh = New-Object System.Windows.Controls.StackPanel; $sh.Orientation = 'Horizontal'; $sh.Margin = '4,12,0,6'
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 9; $dot.Height = 9; $dot.Fill = Brush $c; $dot.Margin = '0,0,8,0'; $dot.VerticalAlignment = 'Center'
    $lb = New-Object System.Windows.Controls.TextBlock; $lb.Text = "$($info.Label)  ·  $(@($scenes[$st]).Count) escenas"; $lb.FontWeight = 'Bold'; $lb.FontSize = 12.5; $lb.Foreground = Brush $c
    [void]$sh.Children.Add($dot); [void]$sh.Children.Add($lb); [void]$list.Children.Add($sh)
    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($name in $scenes[$st]) {
      $card = New-Object System.Windows.Controls.Border
      $card.Background = Brush (Mix-Hex $c $t.Panel 0.12); $card.BorderBrush = Brush $c; $card.BorderThickness = 1.5; $card.CornerRadius = 8; $card.Padding = 6; $card.Margin = '4'; $card.Width = 132
      $sp = New-Object System.Windows.Controls.StackPanel
      $img = New-Object System.Windows.Controls.Image; $img.Width = 120; $img.Height = 88; $img.Stretch = 'Fill'
      [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'NearestNeighbor')
      $frames = [System.Windows.Media.Imaging.BitmapSource[]]@(0..3 | ForEach-Object { Get-PixFrame "$st|$name" $_ })
      [void]$anim.Set($key, $img, $frames, ($st -in 'idle', 'paused')); $key++
      $cap = New-Object System.Windows.Controls.TextBlock; $cap.Text = $sceneText[$name]; $cap.TextWrapping = 'Wrap'; $cap.FontSize = 10.5; $cap.Foreground = Brush $t.Text; $cap.Margin = '1,5,0,0'; $cap.TextAlignment = 'Center'
      [void]$sp.Children.Add($img); [void]$sp.Children.Add($cap); $card.Child = $sp
      [void]$wrap.Children.Add($card)
    }
    [void]$list.Children.Add($wrap)
  }
  $sv.Content = $list; [void]$root.Children.Add($sv)
  $dlg.Content = $root
  $script:galleryAnim = $anim
  $anim.Start()
  $dlg.Add_Closed({ $script:galleryAnim.Stop(); $script:galleryAnim = $null; $script:galleryWin = $null; Trim-Soon })
  $script:galleryWin = $dlg
  [void]$dlg.ShowDialog()
}
$ui.GalleryBtn.Add_Click({ Show-Gallery })

# --- Escenario ------------------------------------------------------------------
# Un mapa (gimnasio, oficina, playa) que llena el panel, con un Claude por sesión que anda hasta el sitio que le toca
# según su estado y lo usa: los que trabajan van a las máquinas o las mesas, los inactivos se sientan juntos y charlan,
# los que terminan celebran en el podio o la fiesta, los que te esperan se acercan a la pantalla, los pausados se
# congelan donde estén. Pulsar uno abre su ficha; arrastrarlo lo deja en otro sitio hasta que cambie de estado.
$stagePx = 3        # DIP por píxel del mapa
$stageWall = 42     # pared (o cielo) arriba
$glyphs['dots'] = '...../#.#.#'
$glyphs['heart'] = '##.##/#####/.###./..#..'
$stageNames = [ordered]@{ gym = 'Gimnasio'; office = 'Oficina'; beach = 'Playa' }
$stageAccents = '#4D9BFF', '#2ED47A', '#FACC15', '#E879F9', '#22D3EE', '#F87171', '#A78BFA', '#FB923C', '#F8FAFC', '#84CC16'
$stageTints = @{
  sleepy = @{ Body = '#A9644F'; Shade = '#87503F'; Top = '#B97560' }
  ice    = @{ Body = '#BFD4E6'; Shade = '#93AFC6'; Top = '#DCE8F2' }
  red    = @{ Body = '#E0605A'; Shade = '#B34843'; Top = '#EA7C76' }
  grey   = @{ Body = '#8C939E'; Shade = '#6E757F'; Top = '#A3A9B2' }
}
# Los sitios de cada mapa: posición relativa (0-1) en el suelo, para qué estado son y si son de uno, de dos (charlan) o de tres
$stageMaps = @{
  gym = @(
    @{ K = 'cinta'; X = 0.18; Y = 0.04; S = 'busy' }, @{ K = 'cinta'; X = 0.47; Y = 0.04; S = 'busy' }, @{ K = 'saco'; X = 0.8; Y = 0.04; S = 'busy' }
    @{ K = 'pesas'; X = 0.14; Y = 0.2; S = 'busy' }, @{ K = 'banca'; X = 0.46; Y = 0.2; S = 'busy' }, @{ K = 'bici'; X = 0.78; Y = 0.2; S = 'busy' }
    @{ K = 'polea'; X = 0.14; Y = 0.37; S = 'busy' }, @{ K = 'podio'; X = 0.52; Y = 0.33; S = 'done'; T = 'trio' }, @{ K = 'botiquin'; X = 0.84; Y = 0.37; S = 'error' }
  )
  office = @(
    @{ K = 'mesa'; X = 0.12; Y = 0.04; S = 'busy' }, @{ K = 'mesa'; X = 0.44; Y = 0.04; S = 'busy' }, @{ K = 'mesa'; X = 0.76; Y = 0.04; S = 'busy' }
    @{ K = 'mesa'; X = 0.12; Y = 0.2; S = 'busy' }, @{ K = 'mesa'; X = 0.44; Y = 0.2; S = 'busy' }, @{ K = 'pizarra'; X = 0.78; Y = 0.2; S = 'busy' }
    @{ K = 'cafe'; X = 0.06; Y = 0.38; S = 'idle'; T = 'pair'; D = 24 }, @{ K = 'fiesta'; X = 0.55; Y = 0.38; S = 'done'; T = 'trio' }, @{ K = 'impresora'; X = 0.9; Y = 0.38; S = 'error' }
    @{ K = 'consola'; X = 0.42; Y = 0.68; S = 'idle'; T = 'row3' }, @{ K = 'arcade'; X = 0.86; Y = 0.52; S = 'idle' }
    @{ K = 'puf'; X = 0.3; Y = 0.87; S = 'idle' }, @{ K = 'puf'; X = 0.66; Y = 0.87; S = 'idle' }
  )
  beach = @(
    @{ K = 'surf'; X = 0.28; Y = 0.05; S = 'busy' }, @{ K = 'surf'; X = 0.72; Y = 0.07; S = 'busy' }
    @{ K = 'castillo'; X = 0.12; Y = 0.25; S = 'busy' }, @{ K = 'voley'; X = 0.38; Y = 0.25; S = 'busy'; T = 'pair'; D = 28 }, @{ K = 'castillo'; X = 0.82; Y = 0.25; S = 'busy' }
    @{ K = 'tumbona'; X = 0.06; Y = 0.41; S = 'idle'; T = 'pair'; D = 24 }, @{ K = 'baile'; X = 0.5; Y = 0.41; S = 'done'; T = 'trio' }, @{ K = 'chiringuito'; X = 0.76; Y = 0.41; S = 'idle'; T = 'pair'; D = 22 }
    @{ K = 'cangrejo'; X = 0.1; Y = 0.18; S = 'error' }, @{ K = 'chapotear'; X = 0.6; Y = 0.19; S = 'done'; E = 1; Dy = 1 }
    @{ K = 'hoguera'; X = 0.3; Y = 0.66; S = 'idle'; T = 'pair'; D = 26; N = 1 }
  )
}
# Campo de fútbol (x0, y0, x1, y1 relativos al suelo); en la playa solo de día
$stageFields = @{ gym = @(0.04, 0.5, 0.96, 0.88); beach = @(0.04, 0.53, 0.96, 0.88) }
$stageDoor = @{ gym = @(0.06, 0); office = @(0.06, 0); beach = @(0.02, 0.4) }
$stageText = @{
  cinta = 'corriendo en la cinta'; pesas = 'levantando pesas'; saco = 'dándole al saco'; bici = 'pedaleando en la bici'
  banco = 'sentado en el banco'; fuente = 'en la fuente de agua'; podio = 'celebrando en el podio'; botiquin = 'en el botiquín, con hielo en la cabeza'
  mesa = 'trabajando en su mesa'; pizarra = 'explicando en la pizarra'; cafe = 'en la máquina de café'; sofa = 'en el sofá'
  fiesta = 'de fiesta con la tarta'; impresora = 'peleándose con la impresora'
  surf = 'surfeando'; castillo = 'haciendo un castillo de arena'; voley = 'jugando al vóley'; tumbona = 'en la tumbona'
  chiringuito = 'en el chiringuito'; baile = 'bailando'; cangrejo = 'huyendo de un cangrejo'
  regar = 'regando las plantas'; beber = 'bebiendo agua'; estirar = 'estirando en la esterilla'; leer = 'leyendo un libro'; acaricia = 'acariciando al gato'
  chuta = 'jugando con la pelota'; conchas = 'cogiendo conchas'; chapotear = 'chapoteando en la orilla'; cometa = 'volando la cometa'; hoguera = 'junto a la hoguera'
  banca = 'en el press de banca'; polea = 'en la máquina de poleas'; consola = 'jugando a la consola en el sofá'; puf = 'jugando con la portátil en el puf'
  arcade = 'jugando a la máquina arcade'; futbol = 'jugando al fútbol'; animar = 'animando el partido'
  frente = 'acercándose a la pantalla: te necesita'; hielo = 'congelado (en pausa)'; deshielo = 'descongelándose'
  mira = 'buscando algo que hacer'; portatil = 'trabajando con el portátil'; sentado = 'descansando en el suelo'; fiestero = 'celebrando'; humo = 'echando humo'
}
# Lo que hace uno que no tiene sitio o al que dejaste en otro lado
$stagePortable = @{ busy = 'portatil'; idle = 'animar'; done = 'fiestero'; waiting = 'frente'; error = 'humo'; unknown = 'mira'; paused = 'hielo'; resuming = 'deshielo' }
$stageColorOf = @{}   # pid -> índice de su color
$stageActors = @{}    # pid -> dónde está y qué hace
$stageFrames = @{}
$stageMap = $null
$stage = New-Object TaskMon.Stage $ui.StageCanvas

function Stage-Confetti($px, [int]$f) {
  $cols = '#FACC15', '#4D9BFF', '#E879F9', '#2ED47A', '#F87171'
  for ($k = 0; $k -lt 6; $k++) { $px.Dot(($k * 11 + 3) % 30 + 1, ($k * 7 + $f * 3) % 14, $cols[$k % 5]) }
}
# Charla de dos: hablan por turnos, cada uno mirando al otro
function Stage-Talk($px, [int]$seat, [int]$f, [string]$glyph, [string]$c) {
  $mine = if ($seat -eq 0) { $f -lt 2 } else { $f -ge 2 }
  if ($mine) { if ($seat -eq 0) { Draw-Bubble $px 21 0 $glyph $c } else { Draw-Bubble $px 2 0 $glyph $c } }
}
function Stage-Eyes([int]$seat) { if ($seat -eq 0) { 'look' } else { 'left' } }

# Muebles del mapa, dibujados en el fondo; (ox, oy) es la esquina del sprite de su primer sitio
function Draw-Furn($px, [string]$kind, [int]$ox, [int]$oy) {
  switch ($kind) {
    'cinta' {
      $px.Rect($ox + 3, $oy + 23, 25, 3, '#374151'); $px.Rect($ox + 3, $oy + 23, 25, 1, '#4B5563')
      $px.Rect($ox + 26, $oy + 10, 2, 13, '#6B7280'); $px.Rect($ox + 23, $oy + 7, 8, 4, '#111827'); $px.Rect($ox + 24, $oy + 8, 6, 2, '#1F2937')
    }
    'pesas' { $px.Rect($ox + 3, $oy + 23, 26, 3, '#3B2F4A'); $px.Rect($ox + 3, $oy + 23, 26, 1, '#4C3D5E'); $px.Rect($ox + 28, $oy + 17, 3, 6, '#374151'); $px.Rect($ox + 28, $oy + 19, 3, 1, '#4B5563') }
    'saco'  { $px.Rect($ox + 30, $oy, 1, 26, '#6B7280'); $px.Rect($ox + 25, $oy, 6, 1, '#6B7280'); $px.Rect($ox + 26, $oy + 1, 1, 3, '#9CA3AF') }
    'bici' {
      $px.Rect($ox + 7, $oy + 25, 20, 1, '#4B5563'); $px.Rect($ox + 13, $oy + 17, 1, 8, '#6B7280'); $px.Rect($ox + 11, $oy + 16, 5, 1, '#111827')
      $px.Rect($ox + 13, $oy + 21, 12, 1, '#6B7280'); $px.Rect($ox + 25, $oy + 11, 1, 14, '#6B7280'); $px.Rect($ox + 23, $oy + 11, 4, 1, '#9CA3AF')
      $px.Glyph($ox + 21, $oy + 20, $glyphs.ring, '#9CA3AF')
    }
    'banco' {
      $px.Rect($ox + 5, $oy + 21, 38, 2, '#8B5E3C'); $px.Rect($ox + 5, $oy + 21, 38, 1, '#A16D45')
      foreach ($lx in 7, 23, 40) { $px.Rect($ox + $lx, $oy + 23, 1, 3, '#6B4A2B') }
    }
    'fuente' { $px.Rect($ox + 26, $oy + 13, 5, 12, '#94A3B8'); $px.Rect($ox + 25, $oy + 12, 7, 2, '#CBD5E1'); $px.Dot($ox + 28, $oy + 11, '#7DD3FC'); $px.Rect($ox + 26, $oy + 25, 5, 1, '#64748B') }
    'podio' {
      $px.Rect($ox + 7, $oy + 25, 18, 12, '#CA8A04'); $px.Rect($ox + 7, $oy + 25, 18, 1, '#FACC15'); $px.Glyph($ox + 15, $oy + 28, '.#/##/.#/.#/.#', '#FEF3C7')
      $px.Rect($ox - 13, $oy + 29, 18, 8, '#64748B'); $px.Rect($ox - 13, $oy + 29, 18, 1, '#94A3B8'); $px.Glyph($ox - 5, $oy + 31, '##./..#/.#./#../###', '#E2E8F0')
      $px.Rect($ox + 27, $oy + 32, 18, 5, '#9A3412'); $px.Rect($ox + 27, $oy + 32, 18, 1, '#C2410C'); $px.Glyph($ox + 35, $oy + 33, '###/..#/###', '#FED7AA')
    }
    'botiquin' {
      $px.Rect($ox + 4, $oy + 21, 22, 2, '#E5E7EB'); $px.Rect($ox + 5, $oy + 23, 1, 3, '#9CA3AF'); $px.Rect($ox + 24, $oy + 23, 1, 3, '#9CA3AF')
      $px.Rect($ox + 23, $oy + 12, 8, 7, '#F8FAFC'); $px.Glyph($ox + 25, $oy + 14, $glyphs.plus, '#DC2626')
    }
    'mesa' {
      $px.Rect($ox + 8, $oy + 14, 2, 11, '#1F2937')
      $px.Rect($ox + 18, $oy + 20, 13, 2, '#7A5A40'); $px.Rect($ox + 18, $oy + 20, 13, 1, '#94704F'); $px.Rect($ox + 19, $oy + 22, 1, 4, '#5C4330'); $px.Rect($ox + 29, $oy + 22, 1, 4, '#5C4330')
      $px.Rect($ox + 22, $oy + 11, 9, 8, '#1F2937'); $px.Rect($ox + 23, $oy + 12, 7, 6, '#0F1726'); $px.Rect($ox + 26, $oy + 19, 1, 1, '#4B5563')
    }
    'pizarra' {
      $px.Rect($ox + 18, $oy + 3, 14, 13, '#94A3B8'); $px.Rect($ox + 19, $oy + 4, 12, 11, '#F8FAFC')
      $px.Rect($ox + 20, $oy + 16, 1, 10, '#64748B'); $px.Rect($ox + 29, $oy + 16, 1, 10, '#64748B')
    }
    'cafe' {
      $px.Rect($ox + 25, $oy + 8, 7, 17, '#374151'); $px.Rect($ox + 26, $oy + 9, 5, 3, '#111827'); $px.Dot($ox + 30, $oy + 10, '#EF4444')
      $px.Rect($ox + 27, $oy + 14, 3, 1, '#9CA3AF'); $px.Rect($ox + 27, $oy + 18, 3, 2, '#F8FAFC')
    }
    'sofa' {
      $px.Rect($ox + 4, $oy + 12, 40, 6, '#4C1D95'); $px.Rect($ox + 4, $oy + 18, 40, 4, '#6D28D9'); $px.Rect($ox + 4, $oy + 18, 40, 1, '#7C3AED')
      $px.Rect($ox + 2, $oy + 14, 3, 8, '#5B21B6'); $px.Rect($ox + 43, $oy + 14, 3, 8, '#5B21B6'); $px.Rect($ox + 5, $oy + 22, 1, 2, '#1F2937'); $px.Rect($ox + 42, $oy + 22, 1, 2, '#1F2937')
    }
    'fiesta' {
      $px.Rect($ox + 6, $oy + 10, 20, 2, '#F8FAFC'); $px.Rect($ox + 11, $oy + 5, 10, 5, '#F9A8D4'); $px.Rect($ox + 11, $oy + 5, 10, 1, '#FDF2F8')
      foreach ($cx in 13, 16, 19) { $px.Dot($ox + $cx, $oy + 4, '#FDE68A'); $px.Dot($ox + $cx, $oy + 3, '#F97316') }
      $px.Rect($ox - 12, $oy + 2, 4, 5, '#EF4444'); $px.Rect($ox - 10, $oy + 7, 1, 8, '#9CA3AF'); $px.Rect($ox + 42, $oy + 3, 4, 5, '#3B82F6'); $px.Rect($ox + 44, $oy + 8, 1, 8, '#9CA3AF')
    }
    'impresora' {
      $px.Rect($ox + 20, $oy + 20, 12, 2, '#6B7280'); $px.Rect($ox + 21, $oy + 22, 1, 4, '#4B5563'); $px.Rect($ox + 30, $oy + 22, 1, 4, '#4B5563')
      $px.Rect($ox + 21, $oy + 14, 10, 6, '#D1D5DB'); $px.Rect($ox + 22, $oy + 16, 8, 1, '#4B5563')
    }
    'castillo' { $px.Rect($ox + 19, $oy + 24, 12, 2, '#C9A465'); $px.Rect($ox + 28, $oy + 20, 3, 4, '#EF4444'); $px.Rect($ox + 28, $oy + 20, 3, 1, '#FCA5A5') }
    'voley' {
      $px.Rect($ox + 30, $oy + 6, 1, 20, '#E5E7EB'); $px.Rect($ox + 29, $oy + 6, 3, 1, '#F8FAFC')
      for ($j = 0; $j -lt 5; $j++) { $px.Dot($ox + 29, $oy + 8 + $j * 2, '#CBD5E1'); $px.Dot($ox + 31, $oy + 8 + $j * 2, '#CBD5E1') }
    }
    'tumbona' {
      $px.Rect($ox + 6, $oy + 21, 16, 2, '#F1F5F9'); $px.Rect($ox + 6, $oy + 21, 16, 1, '#60A5FA'); $px.Rect($ox + 30, $oy + 21, 16, 2, '#F1F5F9'); $px.Rect($ox + 30, $oy + 21, 16, 1, '#60A5FA')
      foreach ($lx in 7, 20, 31, 44) { $px.Rect($ox + $lx, $oy + 23, 1, 2, '#9CA3AF') }
      $px.Rect($ox + 28, $oy + 6, 1, 19, '#E5E7EB')
      for ($i = 0; $i -lt 10; $i++) { $px.Rect($ox + 18 + $i * 2, $oy + 4, 2, 2, $(if ($i % 2) { '#F8FAFC' } else { '#EF4444' })) }
      $px.Rect($ox + 20, $oy + 3, 16, 1, '#EF4444')
    }
    'chiringuito' {
      $px.Rect($ox + 2, $oy, 46, 3, '#A16207'); for ($x = 3; $x -lt 48; $x += 3) { $px.Dot($ox + $x, $oy + 2, '#CA8A04') }
      $px.Rect($ox + 4, $oy + 3, 1, 9, '#78350F'); $px.Rect($ox + 45, $oy + 3, 1, 9, '#78350F')
      $px.Rect($ox + 3, $oy + 11, 44, 5, '#92400E'); $px.Rect($ox + 3, $oy + 11, 44, 1, '#B45309')
      $px.Rect($ox + 20, $oy + 8, 1, 3, '#22C55E'); $px.Rect($ox + 23, $oy + 7, 1, 4, '#3B82F6'); $px.Rect($ox + 26, $oy + 8, 1, 3, '#EF4444')
    }
    'baile' {
      $px.Rect($ox + 11, $oy + 8, 10, 6, '#374151'); $px.Rect($ox + 13, $oy + 7, 6, 1, '#6B7280')
      $px.Glyph($ox + 12, $oy + 9, $glyphs.ring, '#9CA3AF'); $px.Glyph($ox + 16, $oy + 9, $glyphs.ring, '#9CA3AF')
    }
    'cangrejo' { $px.Rect($ox + 24, $oy + 21, 7, 4, '#78716C'); $px.Rect($ox + 25, $oy + 20, 5, 1, '#A8A29E') }
    'regar' { Draw-Plant $px ($ox + 26) ($oy + 25) 1 }
    'banca' {
      $px.Rect($ox + 5, $oy + 9, 1, 15, '#6B7280'); $px.Rect($ox + 26, $oy + 9, 1, 15, '#6B7280'); $px.Rect($ox + 4, $oy + 12, 3, 1, '#9CA3AF'); $px.Rect($ox + 25, $oy + 12, 3, 1, '#9CA3AF')
      $px.Rect($ox + 7, $oy + 20, 18, 2, '#7F1D1D'); $px.Rect($ox + 7, $oy + 20, 18, 1, '#B91C1C'); $px.Rect($ox + 9, $oy + 22, 1, 4, '#374151'); $px.Rect($ox + 22, $oy + 22, 1, 4, '#374151')
    }
    'polea' {
      $px.Rect($ox + 22, $oy + 1, 2, 25, '#4B5563'); $px.Rect($ox + 29, $oy + 1, 2, 25, '#4B5563'); $px.Rect($ox + 22, $oy + 1, 9, 2, '#6B7280')
      $px.Rect($ox + 25, $oy + 3, 1, 22, '#9CA3AF'); $px.Rect($ox + 6, $oy + 20, 9, 2, '#1F2937'); $px.Rect($ox + 9, $oy + 22, 1, 4, '#374151')
    }
    'consola' {
      # Sofá largo para tres, mirando a la tele que queda a su izquierda
      $px.Rect($ox + 2, $oy + 12, 76, 6, '#1E3A8A'); $px.Rect($ox + 2, $oy + 18, 76, 4, '#2563EB'); $px.Rect($ox + 2, $oy + 18, 76, 1, '#3B82F6')
      $px.Rect($ox, $oy + 14, 3, 8, '#1E40AF'); $px.Rect($ox + 77, $oy + 14, 3, 8, '#1E40AF')
      foreach ($k in 26, 50) { $px.Rect($ox + $k, $oy + 12, 1, 6, '#1E40AF') }
      $px.Rect($ox + 4, $oy + 22, 1, 2, '#111827'); $px.Rect($ox + 75, $oy + 22, 1, 2, '#111827')
    }
    'puf' { $px.Circle($ox + 16, $oy + 21, 6, '#7C3AED'); $px.Rect($ox + 9, $oy + 21, 15, 4, '#7C3AED'); $px.Circle($ox + 14, $oy + 19, 2, '#A78BFA') }
    'arcade' {
      $px.Rect($ox + 21, $oy + 3, 11, 23, '#111827'); $px.Rect($ox + 22, $oy + 4, 9, 2, '#DB2777'); $px.Rect($ox + 22, $oy + 6, 9, 8, '#020617')
      $px.Rect($ox + 21, $oy + 15, 11, 3, '#374151'); $px.Dot($ox + 24, $oy + 15, '#EF4444'); $px.Dot($ox + 28, $oy + 16, '#22C55E'); $px.Rect($ox + 22, $oy + 19, 9, 6, '#1E1B4B')
      $px.Rect($ox + 22, $oy + 3, 9, 1, '#F472B6')
    }
    'beber' {
      $px.Rect($ox + 23, $oy + 14, 7, 11, '#E5E7EB'); $px.Rect($ox + 23, $oy + 14, 7, 1, '#F8FAFC'); $px.Rect($ox + 24, $oy + 6, 5, 8, '#B07DD3FC'); $px.Rect($ox + 25, $oy + 5, 3, 1, '#38BDF8')
      $px.Dot($ox + 24, $oy + 17, '#EF4444'); $px.Dot($ox + 28, $oy + 17, '#3B82F6'); $px.Rect($ox + 23, $oy + 25, 7, 1, '#9CA3AF')
    }
    'estirar' { $px.Rect($ox + 4, $oy + 23, 24, 3, '#7C3AED'); $px.Rect($ox + 4, $oy + 23, 24, 1, '#8B5CF6'); $px.Rect($ox + 26, $oy + 23, 2, 3, '#6D28D9') }
    'leer' {
      $px.Rect($ox + 21, $oy + 3, 11, 23, '#5C4330'); $px.Rect($ox + 22, $oy + 4, 9, 21, '#3E2B1E'); $px.Rect($ox + 22, $oy + 10, 9, 1, '#5C4330'); $px.Rect($ox + 22, $oy + 17, 9, 1, '#5C4330')
      $bk = '#DC2626', '#2563EB', '#16A34A', '#CA8A04', '#7C3AED'
      for ($r = 0; $r -lt 3; $r++) { for ($i = 0; $i -lt 4; $i++) { $px.Rect($ox + 22 + $i * 2, $oy + 5 + $r * 7 + ($i % 2), 2, 5 - ($i % 2), $bk[($i + $r) % 5]) } }
    }
  }
}

# Un fotograma de su actividad (32x28, pies en 16,25); $v: 'chat' si tiene con quién hablar
function Draw-Act($px, [string]$kind, [string]$v, [int]$seat, [int]$f, [string]$c) {
  $b = $f % 2
  $px.Rect(9, 25, 14, 1, '#66' + $c.TrimStart('#'))
  switch ($kind) {
    'cinta' {
      for ($k = 0; $k -lt 6; $k++) { $px.Dot(3 + (($k * 4 + 24 - $f * 2) % 24), 24, '#6B7280') }
      $px.Rect(24, 8, [Math]::Min(6, 1 + $f * 2), 2, $c)
      Stage-Claw $px 10 (14 - $b) @{ Arms = $(if ($b) { 'wave' } else { 'left' }); Eyes = 'look'; Step = $b }
    }
    'pesas' {
      $up = $f -eq 1 -or $f -eq 2
      if ($up) { Stage-Claw $px 10 16 @{ Arms = 'hold'; Eyes = 'closed' }; $by = 13 } else { Stage-Claw $px 10 16 @{ Arms = 'side'; Eyes = 'look' }; $by = 19 }
      $px.Rect(4, $by, 24, 1, '#CBD5E1'); $px.Rect(5, $by - 3, 2, 7, '#374151'); $px.Rect(25, $by - 3, 2, 7, '#374151'); $px.Rect(4, $by - 2, 1, 5, '#4B5563'); $px.Rect(27, $by - 2, 1, 5, '#4B5563')
      if ($up) { $px.Dot(11, 16 + $f, '#7DD3FC') }
    }
    'saco' {
      $bx = 23 + @(0, 1, 2, 1)[$f]
      $px.Rect($bx, 4, 6, 14, '#B91C1C'); $px.Rect($bx + 1, 5, 1, 12, '#DC2626'); $px.Rect($bx, 7, 6, 1, '#7F1D1D'); $px.Rect($bx, 15, 6, 1, '#7F1D1D')
      $hit = $b -eq 0
      Stage-Claw $px 8 16 @{ Arms = 'left'; Eyes = $(if ($hit) { 'angry' } else { 'look' }) }
      $px.Rect(7, 19, 2, 2, '#EF4444')
      if ($hit) { $px.Rect(18, 18, 4, 2, '#EF4444'); $px.Glyph(20, 14, $glyphs.plus, '#FDE68A') } else { $px.Rect(18, 19, 2, 2, '#EF4444') }
    }
    'bici' {
      $pd = @(@(20, 19), @(22, 21), @(20, 23), @(18, 21))[$f]
      Stage-Claw $px 8 8 @{ Arms = 'type0'; Eyes = 'look' }
      $px.Rect(16, 17, 1, [Math]::Max(1, $pd[1] - 17), '#B35E44'); $px.Rect($pd[0], $pd[1], 2, 1, '#E5E7EB')
    }
    { $_ -in 'banco', 'fuente', 'cafe', 'sofa', 'tumbona', 'chiringuito' } {
      $sit = $kind -in 'banco', 'sofa', 'tumbona'
      $y = if ($kind -eq 'sofa') { 12 } elseif ($sit) { 13 } else { 16 }
      $o = @{ Eyes = $(if ($v -eq 'chat') { Stage-Eyes $seat } else { 'closed' }) }
      if ($v -ne 'chat') { $o += $stageTints.sleepy }
      if (-not $sit) { $o.Arms = $(if ($seat -eq 0) { 'left' } else { 'pointL' }) }
      Stage-Claw $px 10 $y $o
      $hx = if ($seat -eq 0) { 21 } else { 7 }
      switch ($kind) {
        'banco'       { $px.Rect(12, $y + 5, 8, 1, '#F1F5F9') }
        'tumbona'     { $px.Rect(12, $y + 2, 8, 2, '#111827') }
        'fuente'      { $px.Rect($hx, 15 - $b, 2, 5, '#38BDF8'); $px.Rect($hx, 14 - $b, 2, 1, '#E5E7EB') }
        'cafe'        { $px.Rect($hx, 18, 3, 3, '#E5E7EB'); $px.Rect($hx, 18, 3, 1, '#7C4A2D'); $px.Dot($hx + 1, 16 - $b, '#9CA3AF') }
        'chiringuito' { $px.Rect($hx, 17, 4, 4, '#78350F'); $px.Rect($hx + 1, 17, 2, 1, '#F5F5F4'); $px.Rect($hx + 2, 15, 1, 2, '#F472B6') }
      }
      if ($v -eq 'chat') {
        $g = switch ($kind) { 'sofa' { 'heart' } 'tumbona' { 'note' } 'chiringuito' { 'heart' } default { 'dots' } }
        Stage-Talk $px $seat $f $g $c
      } elseif ($sit) { $px.Glyph($(if ($seat -eq 0) { 23 } else { 3 }) + $b, 6 - $b, $glyphs.zed, '#AEB6C4') }
    }
    { $_ -in 'podio', 'fiesta', 'baile', 'fiestero' } {
      $dx = if ($kind -in 'baile', 'fiestero') { @(0, 1, 0, -1)[$f] } else { 0 }
      $jump = if ($kind -in 'podio', 'fiesta' -and ($f + $seat) % 4 -eq 1) { 2 } else { 0 }
      Stage-Claw $px (10 + $dx) (16 - $jump - $(if ($kind -eq 'baile') { $b } else { 0 })) @{ Arms = $(if (($f + $seat) % 2) { 'up' } else { 'wave' }); Eyes = 'happy'; Step = $b }
      if ($kind -eq 'podio') { $px.Rect(15 + $dx, 20 - $jump, 2, 2, @('#FACC15', '#CBD5E1', '#F97316')[$seat]) }
      if ($kind -eq 'fiesta') { $px.Glyph(14, 13 - $jump, '..#../.###./#####', $c) }
      if ($kind -in 'baile', 'fiestero') { $nc = '#4D9BFF', '#E879F9', '#FACC15', '#2ED47A'; $px.Glyph(24, 6 + $b, $glyphs.note, $nc[($f + $seat) % 4]); $px.Glyph(2, 8 - $b, $glyphs.note, $nc[($f + $seat + 2) % 4]) }
      if ($seat -eq 0 -and $kind -ne 'baile') { Stage-Confetti $px $f }
    }
    'botiquin' {
      Stage-Claw $px 10 13 (@{ Eyes = 'angry' } + $stageTints.red)
      $px.Rect(13, 11, 6, 2, '#93C5FD'); $px.Rect(14, 11, 4, 1, '#DBEAFE')
      if ($b) { Draw-Bubble $px 1 0 'bang' $c }
    }
    'mesa' {
      for ($i = 0; $i -lt 3; $i++) { $px.Rect(24, 13 + $i * 2, 1 + (($f + $i * 2) % 5), 1, $c) }
      $px.Rect(17, 19, 5, 1, '#9CA3AF')
      Stage-Claw $px 8 16 @{ Arms = "type$b"; Eyes = 'look' }
    }
    'pizarra' {
      $lens = 8, 5, 10, 4
      for ($i = 0; $i -lt 4; $i++) { if ($i -le $f) { $px.Rect(20, 6 + $i * 2, $lens[$i], 1, $c) } }
      Stage-Claw $px 8 16 @{ Arms = 'type1'; Eyes = 'look'; Step = $b }
    }
    'impresora' {
      $px.Rect(23, 11 - $b, 5, 3, '#F8FAFC'); $px.Rect(24, 12 - $b, 3, 1, '#9CA3AF')
      $px.Rect(26 + $b, 8 - $b, 2, 1, '#6B7280'); $px.Rect(28 - $b, 5 - $b, 2, 2, '#9CA3AF')
      Stage-Claw $px 7 (16 - $b) (@{ Arms = 'up'; Eyes = 'angry'; Step = $b } + $stageTints.red)
      if (-not $b) { Draw-Bubble $px 0 0 'bang' $c }
    }
    'surf' {
      for ($k = 0; $k -lt 5; $k++) { $px.Dot(3 + (($k * 6 + $f * 2) % 26), 24 + ($k % 2), '#BFE9F5') }
      $px.Rect(5, 22 + $b, 22, 2, '#FACC15'); $px.Rect(5, 22 + $b, 22, 1, '#FDE68A'); $px.Rect(15, 22 + $b, 2, 2, $c)
      Stage-Claw $px 10 (13 + $b) @{ Arms = $(if ($b) { 'up' } else { 'wave' }); Eyes = 'happy'; Step = $b }
    }
    'castillo' {
      $h = 2 + $f
      $px.Rect(20, 25 - $h, 8, $h, '#D4A65A'); $px.Rect(20, 25 - $h, 8, 1, '#E3BC74')
      if ($f -ge 1) { $px.Rect(20, 22 - $h, 2, 3, '#C79545') }
      if ($f -ge 2) { $px.Rect(26, 22 - $h, 2, 3, '#C79545') }
      if ($f -ge 3) { $px.Rect(23, 17 - $h, 1, 5, '#6B7280'); $px.Rect(24, 17 - $h, 2, 2, $c) }
      Stage-Claw $px 6 16 @{ Arms = "type$b"; Eyes = 'look' }
      $px.Rect(18, 17 + $b, 1, 4, '#A16207'); $px.Rect(17, 21 + $b, 3, 1, '#9CA3AF')
    }
    'voley' {
      # Se la pasan: le toca a uno en los dos primeros fotogramas y al otro en los dos últimos; solo, la bota él
      $mine = if ($v -ne 'chat') { $true } elseif ($seat -eq 0) { $f -lt 2 } else { $f -ge 2 }
      $low = $mine -and $b -eq 1
      Stage-Claw $px 10 (16 - $(if ($low) { 1 } else { 0 })) @{ Arms = $(if ($low) { 'up' } else { 'side' }); Eyes = $(if ($mine) { 'up' } else { Stage-Eyes $seat }); Step = $b }
      if ($mine) { $by = if ($b) { 9 } else { 2 }; $px.Rect(15, $by, 3, 3, '#F8FAFC'); $px.Dot(16, $by + 1, '#FACC15') }
    }
    'cangrejo' {
      $cx = 20 + @(0, 1, 2, 1)[$f]
      $px.Rect($cx, 22, 6, 3, '#DC2626'); $px.Rect($cx + 1, 21, 4, 1, '#EF4444'); $px.Dot($cx + 1, 20, '#111827'); $px.Dot($cx + 4, 20, '#111827')
      $px.Rect($cx - 2, 20 - $b, 2, 2, '#EF4444'); foreach ($lx in 0, 2, 4) { $px.Dot($cx + $lx, 25, '#991B1B') }
      Stage-Claw $px 7 (16 - 2 * $b) (@{ Arms = 'up'; Eyes = 'wide' } + $stageTints.red)
      if ($b) { Draw-Bubble $px 0 0 'bang' $c }
    }
    'banca' {
      $up = $f -eq 1 -or $f -eq 2
      if ($up) { Stage-Claw $px 10 13 @{ Arms = 'hold'; Eyes = 'closed' }; $by = 9 } else { Stage-Claw $px 10 13 @{ Arms = 'side'; Eyes = 'look' }; $by = 16 }
      $px.Rect(3, $by, 26, 1, '#CBD5E1'); $px.Rect(4, $by - 3, 2, 7, '#374151'); $px.Rect(26, $by - 3, 2, 7, '#374151')
      if ($up) { $px.Dot(11, 13 + $f, '#7DD3FC') }
    }
    'polea' {
      $pull = $b -eq 1
      $hy = if ($pull) { 14 } else { 9 }
      $px.Rect(24, 18 - $(if ($pull) { 5 } else { 0 }), 5, 6, '#374151'); $px.Rect(24, 19 - $(if ($pull) { 5 } else { 0 }), 5, 1, '#6B7280'); $px.Rect(24, 21 - $(if ($pull) { 5 } else { 0 }), 5, 1, '#6B7280')
      $px.Line(25, 3, 16, $hy, '#9CA3AF'); $px.Rect(12, $hy, 9, 1, '#E5E7EB')
      Stage-Claw $px 8 13 @{ Arms = $(if ($pull) { 'side' } else { 'up' }); Eyes = $(if ($pull) { 'closed' } else { 'look' }) }
    }
    'consola' {
      $hype = $f -eq 3 -and ($seat % 2) -eq 0
      Stage-Claw $px 10 (12 - $(if ($hype) { 2 } else { 0 })) @{ Arms = $(if ($hype) { 'up' } else { 'side' }); Eyes = $(if ($hype) { 'happy' } else { 'left' }) }
      if (-not $hype) { $px.Rect(9, 18 - $b, 5, 2, '#111827'); $px.Dot(10, 18 - $b, '#EF4444'); $px.Dot(12, 18 - $b, '#22C55E') }
    }
    'puf' {
      Stage-Claw $px 10 14 @{ Arms = "type$b"; Eyes = 'look' }
      $px.Rect(14, 19, 7, 3, '#1F2937'); $px.Rect(15, 19, 5, 2, @('#22D3EE', '#A78BFA', '#F472B6', '#34D399')[$f])
      if ($f -eq 2) { $px.Dot(22, 15, '#FDE68A') }
    }
    'arcade' {
      Stage-Claw $px 7 16 @{ Arms = "type$b"; Eyes = 'look'; Step = $b }
      $px.Rect(23, 7 + ($f % 3) * 2, 1, 1, '#22C55E'); $px.Rect(25 + $b, 8, 2, 1, '#F472B6'); $px.Rect(28 - $b, 10, 2, 1, '#FACC15'); $px.Rect(24 + $f, 12, 2, 1, '#38BDF8')
    }
    'listo' {
      Stage-Claw $px 10 (16 - $(if ($f -eq 1) { 1 } else { 0 })) @{ Arms = 'side'; Eyes = 'look'; Step = $b }
    }
    'gol' {
      Stage-Claw $px 10 (16 - 3 * $b) @{ Arms = $(if ($b) { 'up' } else { 'wave' }); Eyes = 'happy'; Step = $b }
      if ($b) { $px.Glyph(2, 4, $glyphs.plus, '#FDE68A'); $px.Glyph(26, 6, $glyphs.plus, '#FDE68A') }
    }
    'animar' {
      Stage-Claw $px 10 (16 - $b) @{ Arms = $(if ($b) { 'up' } else { 'wave' }); Eyes = 'happy'; Step = $b }
      $px.Rect(21, 9 - $b, 1, 9, '#E5E7EB'); $px.Rect(22, 9 - $b, 5, 3, $script:stageAcc)
    }
    'regar' {
      Stage-Claw $px 8 16 @{ Arms = 'type0'; Eyes = 'look' }
      $px.Rect(18, 16, 4, 3, '#22C55E'); $px.Rect(17, 15, 1, 2, '#16A34A'); $px.Line(21, 16, 23, 14, '#22C55E')
      for ($i = 0; $i -lt 3; $i++) { $px.Dot(23 + $i, 15 + (($f + $i) % 4) * 2, '#60A5FA') }
      if ($f -eq 3) { $px.Glyph(26, 8, $glyphs.plus, '#BBF7D0') }
    }
    'beber' {
      Stage-Claw $px 8 16 @{ Arms = 'type0'; Eyes = $(if ($b) { 'closed' } else { 'look' }) }
      $px.Rect(19, 17 - 2 * $b, 2, 3, '#F8FAFC'); $px.Dot(19, 17 - 2 * $b, '#7DD3FC')
    }
    'estirar' {
      $pose = @(@('up', 0), @('wave', 0), @('up', 1), @('pointL', -1))[$f]
      Stage-Claw $px (10 + $pose[1]) (16 - $(if ($f -eq 0) { 1 } else { 0 })) @{ Arms = $pose[0]; Eyes = 'closed' }
      if ($f -eq 2) { $px.Dot(24, 8, '#FDE68A'); $px.Dot(7, 9, '#FDE68A') }
    }
    'leer' {
      Stage-Claw $px 7 16 @{ Arms = 'type0'; Eyes = 'look' }
      $px.Rect(15, 18, 7, 4, '#F8FAFC'); $px.Rect(18, 18, 1, 4, '#94A3B8'); $px.Rect(15, 22, 7, 1, '#B45309')
      if ($f -eq 3) { $px.Rect(18, 16, 3, 3, '#E2E8F0') } else { $px.Rect(16, 19, 2, 1, '#94A3B8'); $px.Rect(19, 20, 2, 1, '#94A3B8') }
    }
    'acaricia' {
      Stage-Claw $px 8 17 @{ Arms = $(if ($b) { 'type0' } else { 'type1' }); Eyes = 'happy' }
      if ($b) { $px.Glyph(22, 6, '##.##/#####/.###./..#..', '#F472B6') }
    }
    'chuta' {
      Stage-Claw $px 10 (16 - 2 * $b) @{ Arms = $(if ($b) { 'up' } else { 'wave' }); Eyes = 'happy'; Step = $b }
      if ($b) { $px.Glyph(24, 5, $glyphs.note, '#FACC15') }
    }
    'conchas' {
      Stage-Claw $px 10 (17 + $b) @{ Arms = "type$b"; Eyes = 'look' }
      $px.Rect(3, 22, 5, 3, '#F472B6'); $px.Rect(3, 22, 5, 1, '#F9A8D4'); $px.Dot(4, 21, '#F8FAFC'); $px.Dot(6, 21, '#FDE68A')
      $px.Glyph(22, 23, '.#./###', '#FBCFE8'); if ($f -eq 2) { $px.Dot(24, 21, '#FFFFFF'); $px.Dot(26, 22, '#FFFFFF') }
    }
    'chapotear' {
      Stage-Claw $px 10 (16 - 2 * $b) @{ Arms = $(if ($b) { 'up' } else { 'side' }); Eyes = 'happy'; Step = $b }
      $px.Rect(6, 24, 20, 2, '#6038BDF8')
      $sp = if ($b) { @(@(6, 19), @(25, 18), @(9, 16), @(23, 15)) } else { @(@(7, 22), @(24, 22)) }
      foreach ($q in $sp) { $px.Dot($q[0], $q[1], '#E0F2FE') }
    }
    'cometa' {
      Stage-Claw $px 8 16 @{ Arms = 'wave'; Eyes = 'up'; Step = $b }
      $kx = 25 + @(0, 1, 2, 1)[$f]; $ky = 2 + $b
      $px.Line(20, 17, $kx, $ky + 4, '#E5E7EB')
      $px.Glyph($kx - 2, $ky, '..#../.###./#####/.###./..#..', $script:stageAcc)
      $px.Dot($kx, $ky + 2, '#FFFFFF'); $px.Dot($kx - 1 + $b, $ky + 6, '#F87171'); $px.Dot($kx + $b, $ky + 8, '#FACC15')
    }
    'hoguera' {
      Stage-Claw $px 10 14 @{ Eyes = $(if ($v -eq 'chat') { Stage-Eyes $seat } else { 'happy' }) }
      $px.Rect(6, 22, 20, 3, '#78350F'); $px.Rect(6, 22, 20, 1, '#92400E')
      $sx = if ($seat -eq 0) { 1 } else { -1 }; $hx = if ($seat -eq 0) { 21 } else { 10 }
      $px.Line($hx, 19, $hx + 6 * $sx, 15, '#A16207'); $px.Rect($hx + 6 * $sx, 13, 2, 2, $(if ($f -ge 2) { '#D6A15E' } else { '#F8FAFC' }))
      if ($v -eq 'chat') { Stage-Talk $px $seat $f 'note' $c }
    }
    'frente' {
      Stage-Claw $px 10 (16 - $b) @{ Arms = $(if ($b) { 'wave' } else { 'side' }); Eyes = 'open'; Step = $b }
      Draw-Bubble $px 22 0 'ask' $c
    }
    'hielo' {
      Stage-Claw $px 10 16 (@{ Eyes = 'closed' } + $stageTints.ice)
      $px.Rect(8, 11, 16, 15, '#5579D4F0'); $px.Rect(8, 11, 16, 1, '#CCB8EEFA'); $px.Rect(8, 11, 1, 15, '#99B8EEFA')
      $px.Dot(10 + ($f * 3) % 12, 12, '#FFFFFFFF')
      Draw-Bubble $px 22 0 'pause' $c
    }
    'deshielo' {
      $px.Rect(6, 25, 20, 1, '#79D4F0')
      Stage-Claw $px 10 16 @{ Eyes = 'open'; Body = '#CC9A88'; Shade = '#A87C6C' }
      $h = 8 - $f * 2
      if ($h -gt 0) { $px.Rect(8, 25 - $h, 16, $h, '#5579D4F0'); $px.Rect(8, 25 - $h, 16, 1, '#99B8EEFA') }
      Draw-Bubble $px 22 0 'play' $c
    }
    'portatil' {
      Draw-Laptop $px 21 14 '#0F1726'
      for ($i = 0; $i -lt 3; $i++) { $px.Rect(23, 16 + $i, 1 + (($f + $i * 2) % 5), 1, $c) }
      Stage-Claw $px 8 16 @{ Arms = "type$b"; Eyes = 'look' }
    }
    'sentado' {
      Stage-Claw $px 10 17 (@{ Eyes = 'closed' } + $stageTints.sleepy)
      $px.Glyph(23 + $b, 7 - $b, $glyphs.zed, '#AEB6C4')
    }
    'humo' {
      Stage-Claw $px 10 16 (@{ Eyes = 'angry'; Step = $b } + $stageTints.red)
      $px.Rect(13 + $b, 12 - $f, 2, 1, '#6B7280'); $px.Rect(16, 11 - ($f % 3), 1, 1, '#6B7280')
      Draw-Bubble $px 22 0 'bang' $c
    }
    default {
      # Sin datos: mira a un lado y a otro buscando qué hacer
      Stage-Claw $px 10 16 (@{ Eyes = $(if ($f -lt 2) { 'look' } else { 'left' }); Step = $b } + $stageTints.grey)
      $px.Glyph(23, 3 + $b, $glyphs.ask, '#9CA3AF')
    }
  }
}

# El mapa: fondo con sus muebles y la lista de sitios en píxeles
# Claude con el accesorio de su color según el mapa; con $stageBlink cierra los ojos (parpadeo) y si está contento se sonroja
function Stage-Claw($px, [int]$x, [int]$y, [hashtable]$o) {
  if ($script:stageBlink -and $o.Eyes -notin 'closed', 'happy') { $o = $o.Clone(); $o.Eyes = 'closed' }
  Draw-Clawd $px $x $y $o
  if ($o.Eyes -eq 'happy') { $px.Dot($x + 2, $y + 4, '#F9A8D4'); $px.Dot($x + 9, $y + 4, '#F9A8D4') }
  $a = $script:stageAcc
  switch ($script:stageKind) {
    'gym'    { $px.Rect($x + 2, $y + 1, 8, 1, $a); $px.Dot($x + 10, $y + 2, $a); $px.Dot($x + 11, $y + 3, $a) }
    'office' { $px.Rect($x + 5, $y + 4, 2, 3, $a); $px.Rect($x + 4, $y + 4, 4, 1, $a) }
    'beach'  { $px.Rect($x + 2, $y - 2, 8, 2, $a); $px.Rect($x + 8, $y - 1, 4, 1, $a) }
  }
}
# Fotogramas: 'act' (su actividad), 'blink' (la misma con los ojos cerrados), 'walk' (según su humor) y 'drag' (cogido)
function Get-StageFrames([string]$what, [string]$kind, [string]$v, [int]$seat, [int]$color, [string]$state) {
  $key = "$($script:stageMap.Scen)|$what|$kind|$v|$seat|$color|$state"
  $umb = $what -eq 'walk' -and $script:stageUmbrella
  if ($umb) { $key += '|u' }
  if ($stageFrames.ContainsKey($key)) { return , $stageFrames[$key] }
  $script:stageKind = $script:stageMap.Scen; $script:stageAcc = $stageAccents[$color]; $script:stageBlink = $what -eq 'blink'
  $c = State-Color $state
  $list = New-Object 'System.Collections.Generic.List[System.Windows.Media.Imaging.BitmapSource]'
  for ($f = 0; $f -lt 4; $f++) {
    $px = New-Object TaskMon.Pix 32, 28
    $b = $f % 2
    switch ($what) {
      'walk' {
        $px.Rect(11, 25, 10, 1, '#44000000')
        switch ($state) {
          'done'    { Stage-Claw $px 10 (16 - 3 * $b) @{ Arms = $(if ($b) { 'up' } else { 'side' }); Eyes = 'happy'; Step = $b } }   # va dando saltitos
          'busy'    { Stage-Claw $px 10 (16 - $b) @{ Arms = $(if ($b) { 'wave' } else { 'left' }); Eyes = 'look'; Step = $b }; if ($f -eq 1) { $px.Dot(9, 17, '#7DD3FC') } }   # con prisa
          'error'   { Stage-Claw $px 10 16 (@{ Arms = 'up'; Eyes = 'angry'; Step = $b } + $stageTints.red) }
          'idle'    { Stage-Claw $px 10 16 (@{ Arms = 'side'; Eyes = 'look'; Step = $b } + $stageTints.sleepy) }   # sin prisa
          'waiting' { Stage-Claw $px 10 (16 - $b) @{ Arms = $(if ($b) { 'wave' } else { 'side' }); Eyes = 'up'; Step = $b } }
          'unknown' { Stage-Claw $px 10 (16 - $b) (@{ Eyes = 'look'; Step = $b } + $stageTints.grey) }
          'play'    { Stage-Claw $px 10 (16 - $b) @{ Arms = $(if ($b) { 'wave' } else { 'left' }); Eyes = 'look'; Step = $b } }   # corriendo detrás de la pelota
          default   { Stage-Claw $px 10 (16 - $b) @{ Arms = $(if ($b) { 'wave' } else { 'side' }); Eyes = 'look'; Step = $b } }
        }
        if ($umb) { $px.Rect(7, 5 - $b, 18, 3, $script:stageAcc); $px.Rect(9, 4 - $b, 14, 1, $script:stageAcc); $px.Rect(7, 7 - $b, 18, 1, '#40000000'); $px.Rect(16, 8 - $b, 1, 9, '#E5E7EB') }
      }
      'land' {
        # Aterriza aplastado, se marea, se sacude y mira a su alrededor
        switch ($f) {
          0 { Stage-Claw $px 10 18 @{ Arms = 'up'; Eyes = 'wide' }; $px.Rect(8, 25, 16, 1, '#55000000') }
          1 { Stage-Claw $px 10 16 @{ Eyes = 'closed' }; foreach ($q in @(@(8, 11), @(16, 9), @(23, 11))) { $px.Glyph($q[0], $q[1], '.#./###/.#.', '#FACC15') } }
          2 { Stage-Claw $px 9 16 @{ Eyes = 'left'; Step = 1 } }
          3 { Stage-Claw $px 11 16 @{ Eyes = 'look'; Arms = 'wave' } }
        }
      }
      'drag' {
        # Cogido en el aire: patalea con los brazos arriba
        Stage-Claw $px (10 + @(0, 1, 0, -1)[$f]) 13 @{ Arms = 'up'; Eyes = 'wide'; Step = $b }
        $px.Rect(12, 25, 8, 1, '#33000000')
      }
      default { Draw-Act $px $kind $v $seat $f $c }
    }
    $px.Outline('#E0101216'); $px.Outline('#50101216')
    $list.Add($px.ToBitmap())
  }
  $script:stageBlink = $false
  $frames = $list.ToArray()
  $stageFrames[$key] = $frames
  , $frames
}
# Fotogramas sueltos para el decorado: $draw recibe el lienzo y el número de fotograma
function New-Frames([int]$w, [int]$h, [int]$n, [scriptblock]$draw, [bool]$outline = $false) {
  $list = New-Object 'System.Collections.Generic.List[System.Windows.Media.Imaging.BitmapSource]'
  for ($f = 0; $f -lt $n; $f++) {
    $px = New-Object TaskMon.Pix $w, $h
    & $draw $px $f
    if ($outline) { $px.Outline('#C0101216') }
    $list.Add($px.ToBitmap())
  }
  , $list.ToArray()
}

# --- Emociones: bocadillos con un icono que sale encima de la cabeza
$stageEmotes = @{}
$stageMoodNames = @{
  busy = 'idea', 'sweat', 'gear', 'excl', 'music'; idle = 'zzz', 'coffee', 'heart', 'note', 'dots'; done = 'heart', 'star', 'music', 'clap'
  waiting = 'question', 'excl', 'dots'; error = 'anger', 'sweat', 'excl'; paused = 'zzz', 'snow'; resuming = 'star', 'excl'; unknown = 'question', 'dots'
}
function Get-Emote([string]$name) {
  if ($stageEmotes.ContainsKey($name)) { return , $stageEmotes[$name] }
  $script:emoName = $name
  $frames = New-Frames 14 13 2 {
    param($px, $f)
    $px.Rect(2, 0, 10, 10, '#FFFFFF'); $px.Rect(1, 1, 12, 8, '#FFFFFF'); $px.Rect(5, 10, 3, 1, '#FFFFFF'); $px.Dot(5, 11, '#FFFFFF')
    $u = $f
    switch ($script:emoName) {
      'heart'    { $px.Glyph(4, 2 - $u + 1, '##.##/#####/#####/.###./..#..', '#EF4444'); $px.Dot(5, 3 - $u + 1, '#FCA5A5') }
      'note'     { $px.Glyph(4, 1 + $u, $glyphs.note, '#3B82F6') }
      'music'    { $px.Glyph(3, 2 + $u, $glyphs.note, '#A855F7'); $px.Glyph(7, 3 - $u, $glyphs.note, '#EC4899') }
      'zzz'      { $px.Glyph(3, 4, '###/.#./###', '#64748B'); $px.Glyph(7, 1 + $u, '###/.#./###', '#94A3B8') }
      'idea'     { $px.Rect(5, 2, 4, 4, '#FACC15'); $px.Rect(4, 3, 6, 2, '#FACC15'); $px.Dot(6, 3, '#FEF9C3'); $px.Rect(6, 6, 2, 2, '#9CA3AF'); if ($u) { $px.Dot(2, 2, '#FACC15'); $px.Dot(11, 2, '#FACC15'); $px.Dot(7, 0, '#FACC15') } }
      'sweat'    { $px.Glyph(5, 1 + $u, '.#../.##./####/####/.##.', '#38BDF8'); $px.Dot(6, 3 + $u, '#E0F2FE') }
      'gear'     { $px.Glyph(4, 2, $(if ($u) { '.#.#./#####/##.##/#####/.#.#.' } else { '#.#.#/.###./##.##/.###./#.#.#' }), '#6B7280') }
      'excl'     { $px.Glyph(6, 2 - $u + 1, '##/##/##/../##', '#EF4444') }
      'question' { $px.Glyph(5, 2, $glyphs.ask, '#F97316') }
      'anger'    { $px.Glyph(4, 2, $(if ($u) { '.#.#./##.##/...../##.##/.#.#.' } else { '#...#/.#.#./...../.#.#./#...#' }), '#DC2626') }
      'star'     { $px.Glyph(4, 2, '..#../.###./#####/.###./.#.#.', '#FACC15'); if ($u) { $px.Dot(2, 1, '#FDE68A'); $px.Dot(11, 7, '#FDE68A') } else { $px.Dot(11, 1, '#FDE68A'); $px.Dot(2, 7, '#FDE68A') } }
      'coffee'   { $px.Rect(4, 4, 5, 4, '#B45309'); $px.Rect(4, 4, 5, 1, '#78350F'); $px.Dot(9, 5, '#B45309'); $px.Dot(9, 6, '#B45309'); $px.Dot(5 + $u, 2, '#9CA3AF'); $px.Dot(7 - $u, 1, '#9CA3AF') }
      'clap'     { $px.Glyph(3 + $u, 3, '.#./###/###/.#.', '#D97757'); $px.Glyph(8 - $u, 3, '.#./###/###/.#.', '#D97757'); $px.Dot(6, 1, '#FACC15') }
      'hi'       { $px.Glyph(4 + $u, 2, '#.#.#/#.#.#/#####/#####/.###.', '#D97757') }
      'dots'     { for ($i = 0; $i -lt 3; $i++) { $px.Dot(4 + $i * 2, 5 - $(if ($i -eq $u) { 1 } else { 0 }), '#475569') } }
      'snow'     { $px.Glyph(4, 2, '#.#.#/.###./#####/.###./#.#.#', $(if ($u) { '#7DD3FC' } else { '#BAE6FD' })) }
      'scared'   { $px.Glyph(4, 2, '#/#/#/./#', '#EF4444'); $px.Glyph(7, 2, '#/#/#/./#', '#EF4444'); $px.Dot(10, 3 + $u, '#38BDF8') }
      'dizzy'    { $pts = if ($u) { @(@(3, 2), @(9, 4), @(5, 7)) } else { @(@(8, 2), @(3, 5), @(9, 7)) }; foreach ($p in $pts) { $px.Glyph($p[0], $p[1], '.#./###/.#.', '#FACC15') } }
    }
  } $true
  $stageEmotes[$name] = $frames
  , $frames
}
function Get-Moods([string]$state) {
  $list = New-Object 'System.Collections.Generic.List[System.Windows.Media.Imaging.BitmapSource[]]'
  foreach ($n in $stageMoodNames[$state]) { $list.Add((Get-Emote $n)) }
  , $list.ToArray()
}

# --- Hora del día y tiempo: el mapa cambia con la hora real y el cielo cada 12 minutos
function Stage-Phase {
  if ($script:stageForce) { return $script:stageForce.Phase }
  $h = (Get-Date).Hour + (Get-Date).Minute / 60
  if ($h -ge 6.5 -and $h -lt 8.5) { 'dawn' } elseif ($h -ge 8.5 -and $h -lt 19) { 'day' } elseif ($h -ge 19 -and $h -lt 21.5) { 'dusk' } else { 'night' }
}
function Stage-Weather {
  if ($script:stageForce) { return $script:stageForce.Weather }
  $n = Get-Date
  $r = New-Object System.Random ($n.DayOfYear * 1000 + [int][Math]::Floor(($n.Hour * 60 + $n.Minute) / 12))
  $v = $r.Next(100)
  if ($v -lt 58) { 'clear' } elseif ($v -lt 82) { 'cloudy' } else { 'rain' }
}
$stageSkies = @{
  clear = @{ dawn = '#2B2F6B,#5B4A8B,#B4688A,#F09A6E,#FCC98A'; day = '#2E6FD1,#3F86E0,#5EA1EC,#86BEF3,#B4D9F8'; dusk = '#241A4A,#4B2A6B,#8E3B6B,#D9604A,#F59A4A'; night = '#04071A,#0A1030,#121B45,#1C2858' }
  grey  = @{ dawn = '#3A3C52,#5A5668,#8C7A7E,#B0958C'; day = '#5F6B7C,#77849A,#93A0B2,#AEB9C6'; dusk = '#2E2A40,#4A3E55,#6E5560,#8C6A60'; night = '#04060C,#0A0F1A,#111827' }
}
# Colores de nube según la hora y el tiempo: base, sombra y brillo
function Stage-CloudColors([string]$ph, [string]$we) {
  if ($ph -eq 'night') { return '#1E293B', '#0F172A', '#334155' }
  if ($we -eq 'rain') { return '#64748B', '#475569', '#94A3B8' }
  if ($we -eq 'cloudy') { return '#CBD5E1', '#94A3B8', '#F1F5F9' }
  switch ($ph) { 'dawn' { '#FBCFE8', '#B4688A', '#FFF1F7' } 'dusk' { '#FDBA74', '#9D4B6B', '#FFE4C7' } default { '#F8FAFC', '#BFD0E3', '#FFFFFF' } }
}
function Draw-Cloud($px, [int]$x, [int]$y, [string]$c, [string]$shade, [string]$hi = '#FFFFFF') {
  $px.Circle($x + 3, $y + 3, 3, $shade); $px.Circle($x + 8, $y + 1, 4, $shade); $px.Circle($x + 13, $y + 3, 3, $shade); $px.Rect($x + 2, $y + 3, 13, 3, $shade)
  $px.Circle($x + 3, $y + 2, 3, $c); $px.Circle($x + 8, $y, 4, $c); $px.Circle($x + 13, $y + 2, 3, $c); $px.Rect($x + 2, $y + 2, 13, 2, $c)
  $px.Rect($x + 6, $y - 3, 4, 1, $hi); $px.Dot($x + 2, $y, $hi); $px.Dot($x + 12, $y, $hi); $px.Dot($x + 5, $y - 2, $hi)
}
# Un trozo de cielo: bandas tramadas, sol con halo o luna con cráteres, estrellas y nubes con volumen
function Draw-SkyBox($px, [int]$x, [int]$y, [int]$w, [int]$h, [string]$ph, [string]$we, [int]$seed, [bool]$bodies) {
  $px.Dither($x, $y, $w, $h, $(if ($we -eq 'clear') { $stageSkies.clear } else { $stageSkies.grey })[$ph])
  if ($ph -eq 'night' -and $we -eq 'clear') {
    $px.Noise($x, $y, $w, [int]($h * 0.85), '#94A3B8', 0.03, $seed); $px.Noise($x, $y, $w, [int]($h * 0.7), '#F8FAFC', 0.012, $seed + 1)
    $r = New-Object System.Random ($seed + 2)
    for ($k = 0; $k -lt [Math]::Max(1, [int]($w / 40)); $k++) { $px.Glyph($x + $r.Next([Math]::Max(1, $w - 3)), $y + $r.Next([Math]::Max(1, [int]($h * 0.6))), '.#./###/.#.', '#E0E7FF') }
  }
  if ($bodies -and $we -ne 'rain') {
    $hr = (Get-Date).Hour + (Get-Date).Minute / 60
    if ($ph -eq 'night') {
      $mx = $x + [int]($w * 0.72); $my = $y + 6
      $px.Glow($mx, $my, 10, '#40C7D2FE'); $px.Circle($mx, $my, 4, '#CBD5E1'); $px.Circle($mx - 1, $my - 1, 3, '#F1F5F9')
      $px.Dot($mx + 1, $my, '#94A3B8'); $px.Dot($mx - 2, $my + 1, '#94A3B8'); $px.Dot($mx, $my - 2, '#CBD5E1')
    } elseif ($we -eq 'clear') {
      $t = [Math]::Max(0, [Math]::Min(1, ($hr - 6.5) / 15))
      $sx = $x + [int]($w * (0.1 + 0.8 * $t)); $sy = $y + [int]($h * (0.75 - 0.6 * [Math]::Sin([Math]::PI * $t)))
      $sc = if ($ph -eq 'day') { '#FDE68A' } else { '#FB923C' }
      $px.Glow($sx, $sy, 14, '#60' + $sc.TrimStart('#')); $px.Circle($sx, $sy, 4, $sc); $px.Circle($sx, $sy, 3, $(if ($ph -eq 'day') { '#FEF3C7' } else { '#FDBA74' })); $px.Circle($sx - 1, $sy - 1, 1, '#FFFBEB')
    }
  }
  $r = New-Object System.Random $seed
  $n = switch ($we) { 'clear' { if ($ph -eq 'night') { 0 } else { 1 } } 'cloudy' { 3 } default { 4 } }
  $cc = Stage-CloudColors $ph $we
  for ($i = 0; $i -lt $n; $i++) { Draw-Cloud $px ($x + $r.Next(-6, [Math]::Max(-5, $w - 10))) ($y + 3 + $r.Next(0, [Math]::Max(1, $h - 9))) $cc[0] $cc[1] $cc[2] }
}
# Planta en maceta de barro, con volumen en hojas y maceta
function Draw-Plant($px, [int]$x, [int]$y, [int]$s) {
  $px.Rect($x - 3, $y - 4, 7, 5, '#B45309'); $px.Rect($x - 3, $y - 4, 2, 5, '#D97706'); $px.Rect($x + 2, $y - 4, 2, 5, '#7C2D12')
  $px.Rect($x - 4, $y - 5, 9, 1, '#EA8A3A'); $px.Rect($x - 3, $y - 5, 7, 1, '#3F2A1A'); $px.Rect($x - 2, $y + 1, 5, 1, '#5C2A0C')
  $px.Circle($x - 3, $y - 6, 3, '#14532D'); $px.Circle($x + 3, $y - 7, 3, '#14532D'); $px.Circle($x, $y - 9 - $s, 4 + $s, '#15803D')
  $px.Circle($x - 1, $y - 10 - $s, 2 + $s, '#22C55E'); $px.Circle($x + 3, $y - 8, 2, '#16A34A'); $px.Circle($x - 3, $y - 7, 2, '#16A34A')
  $px.Dot($x - 2, $y - 12 - $s, '#86EFAC'); $px.Dot($x + 1, $y - 11 - $s, '#86EFAC'); $px.Dot($x + 4, $y - 9, '#4ADE80'); $px.Line($x, $y - 5, $x, $y - 8, '#166534')
}

# --- Gimnasio: nave industrial con ladrillo visto, viga de acero, ventanales de fábrica y suelo de caucho
function Render-Gym($px, $fx, $m, [string]$ph, [string]$we) {
  $W = $m.W; $H = $m.H; $wl = $stageWall
  # Suelo de caucho en losetas biseladas con motas de colores (EPDM)
  $px.Rect(0, $wl, $W, $H - $wl, '#23262D')
  for ($ty = $wl; $ty -lt $H; $ty += 12) { for ($tx = - (([int](($ty - $wl) / 12)) % 2) * 6; $tx -lt $W; $tx += 12) { $px.Bevel($tx, $ty, 12, 12, '#2C3038', '#1A1D22') } }
  $px.Noise(0, $wl, $W, $H - $wl, '#3E4C5E', 0.022, 7); $px.Noise(0, $wl, $W, $H - $wl, '#5A3F3F', 0.012, 8); $px.Noise(0, $wl, $W, $H - $wl, '#16181D', 0.05, 9)
  # Pared de ladrillo visto: tres tonos, luz arriba y llaga en sombra
  $px.Rect(0, 0, $W, $wl, '#3A2622')
  $tones = '#5B3A32', '#663F35', '#52342D'
  $r = New-Object System.Random 4
  for ($by = 4; $by -lt 29; $by += 4) {
    $off = ([int]($by / 4) % 2) * 4
    for ($bx = - $off; $bx -lt $W; $bx += 8) { $px.Rect($bx, $by, 7, 3, $tones[$r.Next(3)]); $px.Rect($bx, $by, 7, 1, '#7A4C40'); $px.Rect($bx + 6, $by + 1, 1, 2, '#43281F') }
  }
  $px.DitherFade(0, 4, $W, 10, '#1A100D', 0.7, 0)
  # Viga de acero con remaches y lámparas industriales
  $px.Rect(0, 0, $W, 4, '#1F2329'); $px.Rect(0, 3, $W, 1, '#2E333C'); $px.Rect(0, 0, $W, 1, '#15181C')
  for ($x = 3; $x -lt $W; $x += 10) { $px.Dot($x, 1, '#6B7280'); $px.Dot($x, 2, '#111827') }
  $script:stageLamps = @()
  $on = $ph -in 'night', 'dusk'
  for ($x = 14; $x -lt $W - 6; $x += 30) {
    $px.Rect($x + 3, 4, 1, 2, '#111827'); $px.Rect($x + 1, 6, 6, 2, '#374151'); $px.Rect($x, 8, 8, 1, '#4B5563'); $px.Rect($x + 1, 6, 2, 1, '#6B7280')
    $px.Rect($x + 2, 9, 4, 1, $(if ($on) { '#FEF3C7' } else { '#9CA3AF' }))
    $script:stageLamps += $x + 4
  }
  # Ventanales de fábrica: marco de acero, cuadrícula, reflejo y repisa
  $script:stageWins = @()
  for ($x = 22; $x + 26 -le $W - 42; $x += 32) {
    $px.Rect($x - 2, 9, 30, 17, '#16191E'); $px.Rect($x - 2, 9, 30, 1, '#2E333C')
    Draw-SkyBox $px $x 10 26 14 $ph $we ($x * 7) $true
    $tb = if ($ph -eq 'night') { '#0B1610', '#060D09' } else { '#24493A', '#173327' }
    $px.Circle($x + 4, 23, 4, $tb[0]); $px.Circle($x + 21, 23, 4, $tb[0]); $px.Circle($x + 12, 24, 5, $tb[1]); $px.Dot($x + 3, 20, '#3D6B55'); $px.Dot($x + 20, 20, '#3D6B55')
    $px.Rect($x + 8, 10, 1, 14, '#16191E'); $px.Rect($x + 17, 10, 1, 14, '#16191E'); $px.Rect($x, 16, 26, 1, '#16191E')
    $px.Line($x + 1, 15, $x + 5, 11, '#38FFFFFF'); $px.Line($x + 10, 15, $x + 14, 11, '#28FFFFFF')
    $px.Rect($x - 3, 26, 32, 2, '#9CA3AF'); $px.Rect($x - 3, 26, 32, 1, '#E5E7EB'); $px.DitherFill($x - 3, 28, 32, 1, '#2A1914', 0.6)
    $script:stageWins += , @($x, 10, 26, 14)
  }
  # Tele/marcador con su marco
  $script:stageTv = @(($W - 37), 9)
  $px.Rect($W - 39, 7, 34, 19, '#0B0D12'); $px.Bevel($W - 39, 7, 34, 19, '#374151', '#030406'); $px.Rect($W - 24, 26, 4, 2, '#374151')
  # Zócalo de hormigón con franja roja y mancuernero
  $px.Rect(0, 29, $W, $wl - 29, '#3A3F48'); $px.Rect(0, 29, $W, 1, '#B91C1C'); $px.Rect(0, 30, $W, 1, '#F1F5F9'); $px.Rect(0, 31, $W, 1, '#991B1B')
  for ($x = 0; $x -lt $W; $x += 16) { $px.Bevel($x, 32, 16, $wl - 34, '#474D58', '#2B2F37') }
  $px.Rect(20, $wl - 5, $W - 30, 1, '#D1D5DB'); $px.Rect(20, $wl - 4, $W - 30, 1, '#6B7280')
  $cols = @(@('#EF4444', '#991B1B'), @('#3B82F6', '#1E3A8A'), @('#22C55E', '#14532D'), @('#FACC15', '#A16207'), @('#A855F7', '#581C87'))
  for ($x = 22; $x -lt $W - 14; $x += 7) { $cc = $cols[[int]($x / 7) % 5]; $px.Rect($x, $wl - 9, 2, 4, $cc[0]); $px.Dot($x + 1, $wl - 6, $cc[1]); $px.Rect($x + 2, $wl - 8, 2, 2, '#D1D5DB'); $px.Rect($x + 4, $wl - 9, 2, 4, $cc[0]); $px.Dot($x + 5, $wl - 6, $cc[1]) }
  $px.Rect(0, $wl - 2, $W, 2, '#1F2329')
  # Oclusión donde la pared toca el suelo
  $px.DitherFade(0, $wl, $W, 7, '#08090B', 0.75, 0)
  # Puerta metálica con cartel de salida
  $px.Rect(3, 12, 14, $wl - 12, '#2E333C'); $px.Rect(4, 13, 12, $wl - 14, '#4B5563'); $px.Bevel(5, 14, 10, 8, '#6B7280', '#374151'); $px.Rect(5, 24, 10, 1, '#374151'); $px.Dot(14, $wl - 12, '#FACC15')
  $px.Rect(4, 6, 12, 5, '#052E1F'); $px.Rect(5, 7, 10, 3, '#10B981'); $px.Rect(6, 8, 8, 1, '#A7F3D0')
  Draw-Court $px $fx $m 'gym'
  Draw-Plant $fx ($W - 7) ($wl + 14) 0
  Draw-Plant $fx 7 ($H - 22) 1
  Draw-Beams $px $ph $we
}

# --- Oficina: papel pintado, friso de madera, ventanales con cortinas y la ciudad, tarima cálida y zona gamer
function Render-Office($px, $fx, $m, [string]$ph, [string]$we) {
  $W = $m.W; $H = $m.H; $wl = $stageWall
  # Tarima: tablas anchas con luz arriba, sombra abajo, vetas y algún nudo
  $r = New-Object System.Random 5
  $woods = @(@('#8A6344', '#A07650', '#6A4830'), @('#7E5A3E', '#93694A', '#5F422D'), @('#946A4B', '#AA7E5A', '#704D35'))
  for ($y = $wl; $y -lt $H; $y += 6) {
    $x = - $r.Next(40)
    while ($x -lt $W) {
      $len = 30 + $r.Next(34); $t = $woods[$r.Next(3)]
      $px.Rect($x, $y, $len, 6, $t[0]); $px.Rect($x, $y, $len, 1, $t[1]); $px.Rect($x, $y + 5, $len, 1, $t[2])
      for ($g = 0; $g -lt 2; $g++) { $gx = $x + 3 + $r.Next([Math]::Max(1, $len - 12)); $px.Rect($gx, $y + 2 + $g * 2, 5 + $r.Next(7), 1, $t[2]) }
      if ($r.Next(6) -eq 0) { $kx = $x + 4 + $r.Next([Math]::Max(1, $len - 8)); $px.Dot($kx, $y + 3, '#4E3524'); $px.Dot($kx + 1, $y + 3, $t[2]) }
      $px.Rect($x, $y, 1, 6, '#4A3222'); $x += $len
    }
  }
  $px.DitherFade(0, $wl, $W, 10, '#24170E', 0.7, 0)
  # Alfombras con cenefa y flecos
  foreach ($s in $m.Stations) {
    if ($s.Kind -eq 'fiesta' -and $s.Seat -eq 0) { Draw-Rug $px ($s.X - 40) ($s.Y - 3) 80 10 '#1E3A8A' '#2563EB' '#93C5FD' }
  }
  # Pared: papel pintado con rombos, más oscuro arriba, moldura y friso de madera
  $px.Dither(0, 0, $W, 28, '#1E2533,#273044,#2F3A52')
  for ($y = 6; $y -lt 27; $y += 6) { for ($x = ([int]($y / 6) % 2) * 3; $x -lt $W; $x += 6) { $px.Dot($x, $y, '#3B4A66'); $px.Dot($x + 1, $y - 1, '#34405A') } }
  $px.Rect(0, 0, $W, 3, '#E5E7EB'); $px.Rect(0, 0, $W, 1, '#F8FAFC'); $px.Rect(0, 2, $W, 1, '#9CA3AF'); $px.DitherFill(0, 3, $W, 2, '#10151F', 0.5)
  $px.Rect(0, 28, $W, $wl - 28, '#6B4A33'); $px.Rect(0, 28, $W, 1, '#A07650'); $px.Rect(0, 29, $W, 1, '#8A6344')
  for ($x = 2; $x -lt $W; $x += 14) { $px.Bevel($x, 31, 12, $wl - 35, '#7F5A3D', '#4A3222') }
  $px.Rect(0, $wl - 3, $W, 3, '#E5E7EB'); $px.Rect(0, $wl - 3, $W, 1, '#F8FAFC'); $px.Rect(0, $wl - 1, $W, 1, '#9CA3AF')
  # Ventanales de marco blanco con cortinas y la ciudad detrás (de noche, encendida)
  $script:stageWins = @(); $script:stageAntennas = @()
  for ($x = 24; $x + 30 -le $W - 22; $x += 38) {
    $px.Rect($x - 6, 3, 42, 1, '#78350F')
    $px.Rect($x - 2, 5, 34, 23, '#F1F5F9'); $px.Rect($x - 2, 5, 34, 1, '#FFFFFF'); $px.Rect($x - 1, 27, 32, 1, '#9CA3AF')
    Draw-SkyBox $px $x 6 30 21 $ph $we ($x * 13) $true
    $br = New-Object System.Random ($x * 3)
    $bc = switch ($ph) { 'night' { '#0F172A', '#0A0F1C' } 'dusk' { '#2A2F4A', '#1F2338' } 'dawn' { '#3A3F5C', '#2C3047' } default { '#5B6B82', '#465569' } }
    $lit = switch ($ph) { 'night' { 0.45 } 'dusk' { 0.22 } 'dawn' { 0.08 } default { 0 } }
    $tall = 0; $tx = 0
    for ($bx = 0; $bx -lt 30; $bx += 5) {
      $bh = 6 + $br.Next(12); $px.Rect($x + $bx, 27 - $bh, 5, $bh, $bc[0]); $px.Rect($x + $bx + 4, 27 - $bh, 1, $bh, $bc[1]); $px.Rect($x + $bx, 27 - $bh, 4, 1, $(if ($ph -eq 'day') { '#7C8BA3' } else { $bc[0] }))
      for ($wy = 27 - $bh + 2; $wy -lt 26; $wy += 2) { for ($wx = 1; $wx -lt 4; $wx += 2) { if ($br.NextDouble() -lt $lit) { $px.Dot($x + $bx + $wx, $wy, '#FDE68A') } elseif ($ph -eq 'day') { $px.Dot($x + $bx + $wx, $wy, '#8FA0B8') } } }
      if ($bh -gt $tall) { $tall = $bh; $tx = $bx }
    }
    $script:stageAntennas += , @(($x + $tx + 2), (27 - $tall - 2))
    $px.Rect($x + $tx + 2, 27 - $tall - 2, 1, 2, '#64748B')
    $px.Rect($x + 14, 6, 2, 21, '#F1F5F9'); $px.Rect($x, 16, 30, 1, '#E5E7EB')
    $px.Line($x + 2, 14, $x + 7, 8, '#40FFFFFF'); $px.Line($x + 18, 14, $x + 23, 8, '#30FFFFFF')
    $px.Rect($x - 3, 28, 36, 2, '#E5E7EB'); $px.Rect($x - 3, 28, 36, 1, '#FFFFFF'); $px.DitherFill($x - 3, 30, 36, 1, '#3E2B1E', 0.5)
    # Cortinas con pliegues
    foreach ($cx in ($x - 6), ($x + 32)) { for ($k = 0; $k -lt 4; $k++) { $px.Rect($cx + $k, 4, 1, 25, $(if ($k % 2) { '#115E59' } else { '#0F766E' })) }; $px.Rect($cx, 28, 4, 1, '#134E4A') }
    $script:stageWins += , @($x, 6, 30, 21)
  }
  # Reloj (va aparte) y estantería con libros
  $script:stageClock = @(($W - 11), 13)
  $px.Rect($W - 20, 20, 16, 12, '#5C4330'); $px.Bevel($W - 20, 20, 16, 12, '#7A5640', '#3E2B1E'); $px.Rect($W - 19, 25, 14, 1, '#3E2B1E')
  $bk = '#DC2626', '#2563EB', '#16A34A', '#CA8A04', '#7C3AED', '#0891B2'
  for ($i = 0; $i -lt 7; $i++) { $px.Rect($W - 19 + $i * 2, 21 + ($i % 2), 2, 4 - ($i % 2), $bk[$i % 6]); $px.Rect($W - 19 + $i * 2, 26 + (($i + 1) % 2), 2, 5 - (($i + 1) % 2), $bk[($i + 3) % 6]) }
  # Puerta de madera con cuarterones
  $px.Rect(3, 9, 14, $wl - 12, '#3E2B1E'); $px.Rect(4, 10, 12, $wl - 13, '#6B4A33'); $px.Bevel(5, 12, 10, 8, '#8A6344', '#4A3222'); $px.Bevel(5, 22, 10, 7, '#8A6344', '#4A3222'); $px.Dot(14, 22, '#FACC15')
  # Zona gamer: alfombra grande, tele con consola y tira de luces
  $gz = $wl + 6 + [int](0.56 * ($H - $wl - 16)); $gb = $wl + 6 + [int](0.94 * ($H - $wl - 16))
  Draw-Rug $px 4 $gz ($W - 8) ($gb - $gz) '#2E1065' '#4C1D95' '#C4B5FD'
  $ty = $wl + 6 + [int](0.68 * ($H - $wl - 16))
  $px.Glow(19, $ty - 16, 24, '#30A855F7')
  $fx.Rect(6, $ty - 6, 26, 6, '#1F2937'); $fx.Bevel(6, $ty - 6, 26, 6, '#374151', '#111827'); $fx.Rect(12, $ty - 4, 8, 2, '#111827'); $fx.Dot(18, $ty - 3, '#22C55E')
  $fx.Rect(5, $ty - 26, 28, 19, '#0B0D12'); $fx.Bevel(5, $ty - 26, 28, 19, '#374151', '#030406'); $fx.Rect(17, $ty - 7, 4, 1, '#374151')
  $fx.Rect(6, $ty - 7, 26, 1, '#A855F7')
  $script:stageGameTv = @(7, ($ty - 25))
  # Plantas, archivador y papelera
  Draw-Plant $fx ($W - 6) ($wl + 16) 1
  $fx.Rect($W - 12, $H - 34, 9, 14, '#6B7280'); $fx.Bevel($W - 12, $H - 34, 9, 14, '#9CA3AF', '#4B5563'); $fx.Rect($W - 9, $H - 30, 3, 1, '#D1D5DB'); $fx.Rect($W - 9, $H - 25, 3, 1, '#D1D5DB')
  $fx.Rect($W - 20, $H - 24, 5, 5, '#374151'); $fx.Rect($W - 20, $H - 24, 5, 1, '#4B5563'); $fx.Dot($W - 19, $H - 25, '#F8FAFC'); $fx.Dot($W - 17, $H - 26, '#F8FAFC')
  Draw-Beams $px $ph $we
}
# Alfombra con cenefa, dibujo interior y flecos a los lados
function Draw-Rug($px, [int]$x, [int]$y, [int]$w, [int]$h, [string]$dark, [string]$base, [string]$hi) {
  $px.Rect($x, $y, $w, $h, $dark); $px.Rect($x + 2, $y + 2, $w - 4, $h - 4, $base)
  $px.DitherFill($x + 2, $y + 2, $w - 4, $h - 4, $dark, 0.15)
  for ($k = $x + 4; $k -lt $x + $w - 4; $k += 4) { $px.Dot($k, $y + 1, $hi); $px.Dot($k + 2, $y + $h - 2, $hi) }
  for ($k = $y + 2; $k -lt $y + $h - 1; $k += 2) { $px.Dot($x - 1, $k, '#E7DCC8'); $px.Dot($x + $w, $k, '#E7DCC8') }
}

# --- Playa: cielo y mar en bandas tramadas, isla y faro, orilla mojada, arena con dunas y conchas
function Render-Beach($px, $fx, $m, [string]$ph, [string]$we) {
  $W = $m.W; $H = $m.H; $wl = $stageWall
  $hz = $wl - 8
  $seaEnd = $wl + 6 + [int](0.17 * ($H - $wl - 16))
  $script:stageSea = @($hz, $seaEnd)
  Draw-SkyBox $px 0 0 $W $hz $ph $we 21 $true
  # Isla con dos verdes, palmera, y el faro con luz y sombra
  $isl = if ($ph -eq 'night') { '#0A1712', '#0F2219' } else { '#1E3A2F', '#2D5A44' }
  $px.Circle(26, $hz + 1, 6, $isl[0]); $px.Circle(34, $hz + 2, 4, $isl[0]); $px.Circle(25, $hz - 1, 4, $isl[1]); $px.Rect(19, $hz, 20, 2, $isl[0])
  $px.Line(28, $hz - 4, 30, $hz - 10, '#4A2E1A'); $px.Circle(30, $hz - 11, 2, $isl[0]); $px.Line(26, $hz - 12, 34, $hz - 10, $isl[1]); $px.Line(27, $hz - 9, 33, $hz - 12, $isl[0])
  $lx = $W - 24
  $px.Circle($lx + 1, $hz + 1, 5, '#374151'); $px.Circle($lx, $hz, 3, '#4B5563')
  $px.Rect($lx - 1, $hz - 14, 4, 14, '#F8FAFC'); $px.Rect($lx + 2, $hz - 14, 1, 14, '#CBD5E1'); $px.Rect($lx - 1, $hz - 10, 4, 2, '#DC2626'); $px.Rect($lx - 1, $hz - 5, 4, 2, '#DC2626'); $px.Rect($lx + 2, $hz - 10, 1, 2, '#991B1B'); $px.Rect($lx + 2, $hz - 5, 1, 2, '#991B1B')
  $px.Rect($lx - 2, $hz - 15, 6, 1, '#1F2937'); $px.Rect($lx - 1, $hz - 18, 4, 3, '#374151'); $px.Rect($lx, $hz - 17, 2, 1, $(if ($ph -in 'night', 'dusk') { '#FDE68A' } else { '#94A3B8' })); $px.Rect($lx - 1, $hz - 19, 4, 1, '#DC2626')
  $script:stageLight = @(($lx + 1), ($hz - 17))
  # Mar en bandas tramadas, crestas y el camino de luz del sol o la luna
  $sea = switch ($ph) { 'night' { '#050C1C,#0A1A33,#10294A,#173A5C' } 'dusk' { '#1E2A55,#30386A,#6A4A70,#B0605A' } 'dawn' { '#2A4570,#3D5C86,#7A6E8A,#C98A7E' } default { '#1B5E8C,#1F78A8,#2794BE,#3BB0CF,#6FD0DF' } }
  if ($we -ne 'clear' -and $ph -ne 'night') { $sea = '#2F4558,#3E5A6E,#4F7085,#6A8A9A' }
  $px.Dither(0, $hz, $W, $seaEnd - $hz, $sea)
  $crest = if ($ph -eq 'night') { '#2B4D72' } else { '#8FD9EC' }
  for ($y = $hz + 3; $y -lt $seaEnd - 2; $y += 4) { for ($x = ($y * 5) % 13; $x -lt $W; $x += 13) { $px.Rect($x, $y, 3, 1, $crest); $px.Dot($x + 3, $y - 1, $crest) } }
  if ($we -ne 'rain') {
    $rx = if ($ph -eq 'night') { [int]($W * 0.72) } else { [int]($W / 2) }
    $px.DitherFill($rx - 4, $hz + 1, 9, $seaEnd - $hz - 2, $(if ($ph -eq 'night') { '#CBD5E1' } else { '#FEF3C7' }), 0.3)
  }
  # Orilla mojada con brillo, y arena en bandas con dunas, conchas, estrellas y piedras
  $sand = switch ($ph) { 'night' { '#5E5646,#524B3E,#463F35' } 'dusk' { '#D4A27A,#C08C68,#A87658' } 'dawn' { '#E3BE95,#D8AE86,#C99C78' } default { '#EED7A6,#E6C892,#DBB77F,#CFA870' } }
  $px.Dither(0, $seaEnd, $W, $H - $seaEnd, $sand)
  $wet = if ($ph -eq 'night') { '#3F3A30' } else { '#B99B68' }
  $px.Rect(0, $seaEnd, $W, 4, $wet); $px.DitherFill(0, $seaEnd + 4, $W, 2, $wet, 0.5); $px.Rect(0, $seaEnd + 1, $W, 1, $(if ($ph -eq 'night') { '#4E4A40' } else { '#D9C59A' }))
  $r = New-Object System.Random 13
  $lite = if ($ph -eq 'night') { '#6B6352' } else { '#F6E4BC' }; $dark = if ($ph -eq 'night') { '#3C362C' } else { '#C29A62' }
  for ($k = 0; $k -lt 26; $k++) { $sx = $r.Next(2, $W - 6); $sy = $r.Next($seaEnd + 8, $H - 4); $px.Rect($sx, $sy, 4, 1, $lite); $px.Rect($sx + 1, $sy + 1, 4, 1, $dark) }
  for ($k = 0; $k -lt 9; $k++) { $sx = $r.Next(6, $W - 6); $sy = $r.Next($seaEnd + 8, $H - 6); $px.Glyph($sx, $sy, '.#./###', $(if ($k % 3) { '#FBCFE8' } else { '#F8FAFC' })); $px.Dot($sx + 2, $sy + 1, '#D8A7B8') }
  foreach ($p in @(@(40, ($seaEnd + 20)), @(($W - 40), ($H - 50)))) { $px.Glyph($p[0], $p[1], '..#../#####/.###./##.##', '#F97316'); $px.Dot($p[0] + 2, $p[1] + 1, '#FDBA74') }
  for ($k = 0; $k -lt 7; $k++) { $sx = $r.Next(4, $W - 4); $sy = $r.Next($seaEnd + 10, $H - 4); $px.Rect($sx, $sy, 2, 2, '#9CA3AF'); $px.Dot($sx, $sy, '#E5E7EB'); $px.Dot($sx + 1, $sy + 1, '#6B7280') }
  for ($k = 0; $k -lt 6; $k++) { $px.Rect($r.Next($W), $seaEnd + 4 + $r.Next(3), 3, 1, '#3F6212') }
  if ($ph -ne 'night') { Draw-Court $px $fx $m 'beach' }
}

# Campo de fútbol. Gimnasio: parqué de madera con brillos, banda exterior y áreas pintadas. Playa: líneas de cuerda en la arena
function Draw-Court($px, $fx, $m, [string]$kind) {
  $f = $m.Field; if (-not $f) { return }
  $x0, $y0, $x1, $y1, $gh = $f
  $cy = [int](($y0 + $y1) / 2); $cx = [int](($x0 + $x1) / 2)
  if ($kind -eq 'gym') {
    $px.Rect($x0 - 3, $y0 - 3, $x1 - $x0 + 7, $y1 - $y0 + 7, '#7C2D12'); $px.Bevel($x0 - 3, $y0 - 3, $x1 - $x0 + 7, $y1 - $y0 + 7, '#9A3412', '#5C2009')
    $r = New-Object System.Random 17
    $woods = @(@('#C88A4E', '#D99D62'), @('#BF8146', '#CF9157'), @('#D09358', '#DFA66C'))
    for ($y = $y0; $y -le $y1; $y += 3) {
      $x = $x0 - $r.Next(18)
      while ($x -le $x1) {
        $len = 14 + $r.Next(16); $xs = [Math]::Max($x0, $x); $xe = [Math]::Min($x1, $x + $len - 1)
        if ($xe -ge $xs) { $t = $woods[$r.Next(3)]; $px.Rect($xs, $y, $xe - $xs + 1, [Math]::Min(3, $y1 - $y + 1), $t[0]); $px.Rect($xs, $y, $xe - $xs + 1, 1, $t[1]); $px.Dot($xs, $y + 1, '#9A6232') }
        $x += $len
      }
    }
    # Brillo del barniz bajo las lámparas
    foreach ($lx in $script:stageLamps) { $px.DitherFill([Math]::Max($x0, $lx - 6), $y0, 12, $y1 - $y0, '#F2C994', 0.18) }
    # Áreas pintadas de azul
    foreach ($side in 0, 1) { $ax = if ($side) { $x1 - 14 } else { $x0 }; $px.Rect($ax, $cy - $gh - 6, 15, 2 * $gh + 12, '#2F5FBF'); $px.DitherFill($ax, $cy - $gh - 6, 15, 2 * $gh + 12, '#3B6FD4', 0.3) }
    $px.Circle($cx, $cy, 9, '#2F5FBF'); $px.Circle($cx, $cy, 8, '#3567C9')
    $lc = '#F8FAFC'
  } else {
    $lc = '#F8FAFC'
  }
  $px.Rect($x0, $y0, $x1 - $x0 + 1, 1, $lc); $px.Rect($x0, $y1, $x1 - $x0 + 1, 1, $lc); $px.Rect($x0, $y0, 1, $y1 - $y0 + 1, $lc); $px.Rect($x1, $y0, 1, $y1 - $y0 + 1, $lc)
  $px.Rect($cx, $y0, 1, $y1 - $y0, $lc)
  for ($a = 0; $a -lt 40; $a++) { $t = $a * [Math]::PI / 20; $px.Dot($cx + [int][Math]::Round(9 * [Math]::Cos($t)), $cy + [int][Math]::Round(9 * [Math]::Sin($t)), $lc) }
  $px.Rect($cx - 1, $cy, 3, 1, $lc); $px.Rect($cx, $cy - 1, 1, 3, $lc)
  foreach ($side in 0, 1) {
    $ax = if ($side) { $x1 - 14 } else { $x0 }
    $px.Rect($(if ($side) { $ax } else { $x0 }), $cy - $gh - 6, 15, 1, $lc); $px.Rect($(if ($side) { $ax } else { $x0 }), $cy + $gh + 6, 15, 1, $lc)
    $px.Rect($(if ($side) { $x1 - 14 } else { $x0 + 14 }), $cy - $gh - 6, 1, 2 * $gh + 13, $lc)
    $px.Dot($(if ($side) { $x1 - 9 } else { $x0 + 9 }), $cy, $lc)
    # Portería: postes blancos con sombra, red tramada
    $gx = if ($side) { $x1 + 1 } else { $x0 - 5 }
    $fx.Rect($gx, $cy - $gh, 5, 1, '#F8FAFC'); $fx.Rect($gx, $cy + $gh, 5, 1, '#F8FAFC'); $fx.Rect($(if ($side) { $gx } else { $gx + 4 }), $cy - $gh, 1, 2 * $gh + 1, '#F8FAFC')
    $fx.Rect($(if ($side) { $gx + 4 } else { $gx }), $cy - $gh, 1, 2 * $gh + 1, '#94A3B8')
    $fx.DitherFill($gx, $cy - $gh + 1, 5, 2 * $gh - 1, '#CBD5E1', 0.35)
  }
  if ($kind -eq 'beach') {
    foreach ($q in @(@($x0, $y0), @($x1, $y0), @($x0, $y1), @($x1, $y1))) { $fx.Rect($q[0], $q[1] - 6, 1, 6, '#F8FAFC'); $fx.Rect($q[0] + 1, $q[1] - 6, 3, 2, '#EF4444'); $fx.Dot($q[0] + 1, $q[1] - 5, '#B91C1C') }
  }
}

# Lluvia: gotas en diagonal que caen
function Rain-Frames([int]$w, [int]$h, [int]$dens) {
  $script:rainArgs = @($w, $h, $dens)
  New-Frames $w $h 4 {
    param($px, $f)
    $w, $h, $d = $script:rainArgs
    $r = New-Object System.Random 77
    for ($k = 0; $k -lt $d; $k++) {
      $x = $r.Next($w); $y = ($r.Next($h) + $f * [int]($h / 4)) % $h
      $px.Line($x, $y, $x - 1, $y + 3, '#90BFDBFE')
    }
  }
}
function Stage-Glow([string]$id, [double]$x, [double]$y, [int]$r, [string]$color) {
  $script:glowArgs = @($r, $color)
  $fr = New-Frames ($r * 2 + 1) ($r * 2 + 1) 1 { param($px, $f) $px.Glow($script:glowArgs[0], $script:glowArgs[0], $script:glowArgs[0], $script:glowArgs[1]) }
  $stage.AddProp($id, $fr, $x, $y, $r, $r, 1, 920000)
}

# Rayos de sol que entran por los ventanales y caen sobre el suelo
function Draw-Beams($px, [string]$ph, [string]$we) {
  if ($we -ne 'clear' -or $ph -eq 'night') { return }
  $col = if ($ph -eq 'day') { 'FFF3C7' } else { 'FDBA74' }
  foreach ($w in $script:stageWins) {
    for ($k = 0; $k -lt 44; $k++) { $px.Rect($w[0] + [int]($k * 0.6), $stageWall + $k, $w[2], 1, ('#{0:X2}{1}' -f [int](30 * (1 - $k / 44)), $col)) }
  }
}
function Props-Gym($m, [string]$ph, [string]$we) {
  $W = $m.W; $H = $m.H; $wl = $stageWall
  # La tele de la pared hace de marcador del partido
  Stage-Score
  # Robot aspirador dando vueltas por el suelo
  $rb = New-Frames 9 5 2 { param($px, $f) $px.Rect(1, 1, 7, 4, '#374151'); $px.Rect(2, 0, 5, 1, '#4B5563'); $px.Rect(0, 2, 9, 2, '#374151'); $px.Rect(3, 1, 3, 1, '#6B7280'); $px.Dot(4, 2, $(if ($f) { '#22C55E' } else { '#14532D' })) } $true
  $stage.AddProp('robot', $rb, 10, $H - 20, 4, 4, 0.5, -1)
  $stage.PropPath('robot', [double[]]@(10, ($H - 20), 1, ($W - 10), ($H - 20), 2, ($W - 10), ($wl + 30), 1, ($W / 2), ($wl + 52), 3, 10, ($wl + 30), 0), 7, $false, $false)
  # Burbujas en la fuente de agua
  $bub = New-Frames 4 7 3 { param($px, $f) $px.Dot(1 + ($f % 2), 6 - $f * 2, '#E0F2FE'); $px.Dot(2, (9 - $f * 2) % 7, '#E0F2FE') }
  $cool = $m.Stations | Where-Object { $_.Kind -eq 'beber' } | Select-Object -First 1
  if ($cool) { $stage.AddProp('bubbles', $bub, $cool.X + 8, $cool.Y - 19, 0, 0, 0.3, 4) }
  # Si se le cruza un Claude, el robot se para, pita y le da un susto
  $rbs = New-Frames 9 5 2 { param($px, $f) $px.Rect(1, 1, 7, 4, '#374151'); $px.Rect(2, 0, 5, 1, '#4B5563'); $px.Rect(0, 2, 9, 2, '#374151'); $px.Rect(3, 1, 3, 1, '#6B7280'); $px.Dot(4, 2, $(if ($f) { '#EF4444' } else { '#7F1D1D' })) } $true
  $stage.PropSensor('robot', $rbs, 11, $true); $stage.PropStartle('robot', (Get-Emote 'excl'), 9)
  Stage-Door 3 12 $wl '#3F4654' '#4B5563'
  if (-not ($stage.BallX -ge 0)) { $stage.SetBall((Ball-Frames 'gym'), (($m.Field[0] + $m.Field[2]) / 2), (($m.Field[1] + $m.Field[3]) / 2)) }
  Stage-Dust $ph $we
  # Lluvia en los ventanales
  if ($we -eq 'rain') { $i = 0; foreach ($w in $script:stageWins) { $stage.AddProp("rain$i", (Rain-Frames 26 15 14), $w[0], $w[1], 0, 0, 0.12, 4); $i++ } }
  # De noche se encienden las luces
  if ($ph -in 'night', 'dusk') {
    $i = 0; foreach ($lx in $script:stageLamps) { Stage-Glow "lamp$i" $lx 8 22 '#50FDE68A'; $i++ }
    Stage-Glow 'exit' 10 9 8 '#6034D399'
    Stage-Glow 'tvglow' ($script:stageTv[0] + 15) ($script:stageTv[1] + 8) 18 '#3060A5FA'
  }
}

function Props-Office($m, [string]$ph, [string]$we) {
  $W = $m.W; $H = $m.H; $wl = $stageWall
  # La tele de la zona gamer echa un partido de fútbol de videojuego
  $game = New-Frames 26 17 8 {
    param($px, $f)
    $px.Rect(0, 0, 26, 17, '#166534'); for ($x = 0; $x -lt 26; $x += 4) { $px.Rect($x, 2, 2, 15, '#15803D') }
    $px.Rect(0, 0, 26, 2, '#0B0D12'); $px.Rect(2, 0, 3, 1, '#EF4444'); $px.Rect(21, 0, 3, 1, '#3B82F6')
    $px.Rect(13, 2, 1, 15, '#BBF7D0'); $px.Rect(0, 7, 1, 5, '#F8FAFC'); $px.Rect(25, 7, 1, 5, '#F8FAFC')
    $bxs = 6, 9, 13, 16, 19, 22, 24, 13; $bys = 9, 6, 8, 11, 9, 8, 9, 9
    $px.Dot($bxs[$f], $bys[$f], '#FFFFFF')
    $px.Rect($bxs[$f] - 2, $bys[$f] + 1, 1, 2, '#EF4444'); $px.Rect([Math]::Min(23, $bxs[$f] + 3), $bys[($f + 3) % 8], 1, 2, '#3B82F6'); $px.Rect(22, 8 + ($f % 3), 1, 2, '#3B82F6'); $px.Rect(4, 9 - ($f % 2), 1, 2, '#EF4444')
    if ($f -eq 6) { $px.Glyph(7, 6, '###.###.#../#...#.#.#../#.#.#.#.#../###.###.###', '#FACC15') }
  }
  $stage.AddProp('gametv', $game, $script:stageGameTv[0], $script:stageGameTv[1], 0, 0, 0.3, 3)
  Stage-Glow 'gameglow' ($script:stageGameTv[0] + 13) ($script:stageGameTv[1] + 9) 20 '#3060A5FA'
  Stage-Clock
  # El gato de la oficina: pasea, se para a mirar y sigue
  $cat = New-Frames 11 8 4 {
    param($px, $f)
    $c = '#F59E0B'; $d = '#B45309'
    $px.Rect(2, 3, 7, 3, $c); $px.Rect(7, 1, 3, 3, $c); $px.Dot(7, 0, $c); $px.Dot(9, 0, $c); $px.Dot(9, 2, '#111827')
    $px.Rect(3, 3, 1, 3, $d); $px.Rect(5, 3, 1, 3, $d)
    $legs = if ($f % 2) { 2, 4, 6, 8 } else { 3, 5, 7, 8 }
    foreach ($lx in $legs) { $px.Dot($lx - 1, 6, $c) }
    $px.Dot(1, 3 - ($f % 2), $c); $px.Dot(0, 2 - ($f % 2), $c)
  } $true
  $stage.AddProp('cat', $cat, 30, $H - 30, 5, 7, 0.2, -1)
  # Si un Claude se le acerca, el gato se sienta y ronronea
  $sit = New-Frames 11 10 2 {
    param($px, $f)
    $c = '#F59E0B'
    $px.Rect(3, 5, 6, 4, $c); $px.Rect(6, 3, 4, 3, $c); $px.Dot(6, 2, $c); $px.Dot(9, 2, $c); $px.Dot(7, 4, '#111827'); $px.Dot(9, 4, '#111827')
    $px.Rect(1, 7 - $f, 2, 1, $c); $px.Rect(3, 8, 2, 1, '#B45309')
    if ($f) { $px.Glyph(0, 0, '#.#/###/.#.', '#F472B6') }
  } $true
  $stage.PropSensor('cat', $sit, 11, $true)
  $cy = $wl + [int](0.62 * ($H - $wl - 16)) + 6
  $stage.PropPath('cat', [double[]]@(30, ($H - 30), 4, ($W - 30), ($H - 30), 3, ($W - 28), $cy, 5, 40, $cy, 2, 20, ($wl + 20), 6), 9, $false, $true)
  # Lucecitas rojas en lo alto de los edificios
  $al = New-Frames 1 1 2 { param($px, $f) if ($f) { $px.Dot(0, 0, '#EF4444') } }
  $i = 0; foreach ($a in $script:stageAntennas) { $stage.AddProp("ant$i", $al, $a[0], $a[1] - 1, 0, 0, 0.8 + $i * 0.1, 3); $i++ }
  if ($we -eq 'rain') { $i = 0; foreach ($w in $script:stageWins) { $stage.AddProp("rain$i", (Rain-Frames 32 21 18), $w[0], $w[1], 0, 0, 0.12, 4); $i++ } }
  Stage-Door 3 9 ($wl - 3) '#4A3324' '#6B4A33'
  if (-not ($stage.BallX -ge 0)) { $stage.SetBall((Ball-Frames 'office'), ($W * 0.6), ($H - 30)) }
  Stage-Dust $ph $we
  if ($ph -in 'night', 'dusk') {
    for ($x = 14; $x -lt $W - 6; $x += 36) { Stage-Glow "lamp$x" $x 4 22 '#48FDE68A' }
    $i = 0; foreach ($s in $m.Stations) { if ($s.Kind -eq 'mesa') { Stage-Glow "scr$i" ($s.X + 10) ($s.Y - 10) 10 '#4060A5FA'; $i++ } }
  }
}
# Reloj de pared con la hora de verdad; se redibuja cuando cambia el minuto
function Stage-Clock {
  if (-not $script:stageClock) { return }
  $n = Get-Date; $script:clockArgs = @(($n.Hour % 12), $n.Minute)
  $fr = New-Frames 11 11 1 {
    param($px, $f)
    $px.Circle(5, 5, 5, '#E5E7EB'); $px.Circle(5, 5, 4, '#F8FAFC')
    foreach ($k in 0, 3, 6, 9) { $a = $k * [Math]::PI / 6; $px.Dot(5 + [int][Math]::Round(4 * [Math]::Sin($a)), 5 - [int][Math]::Round(4 * [Math]::Cos($a)), '#64748B') }
    $hh, $mm = $script:clockArgs
    $am = $mm * [Math]::PI / 30; $ah = ($hh + $mm / 60) * [Math]::PI / 6
    $px.Line(5, 5, 5 + [int][Math]::Round(3.5 * [Math]::Sin($am)), 5 - [int][Math]::Round(3.5 * [Math]::Cos($am)), '#111827')
    $px.Line(5, 5, 5 + [int][Math]::Round(2.2 * [Math]::Sin($ah)), 5 - [int][Math]::Round(2.2 * [Math]::Cos($ah)), '#DC2626')
  } $true
  $script:clockMinute = $n.Minute
  $stage.AddProp('clock', $fr, $script:stageClock[0], $script:stageClock[1], 5, 5, 1, 3)
}

function Props-Beach($m, [string]$ph, [string]$we) {
  $W = $m.W; $H = $m.H; $wl = $stageWall
  $hz, $seaEnd = $script:stageSea
  # Olas que avanzan y espuma en la orilla
  $script:waveArgs = @($W, ($seaEnd - $hz), $ph)
  $waves = New-Frames $W ($seaEnd - $hz) 4 {
    param($px, $f)
    $w, $h, $p = $script:waveArgs
    $c = if ($p -eq 'night') { '#5093C5FD' } else { '#A0E0F7FF' }
    for ($y = 3; $y -lt $h - 1; $y += 5) { for ($x = (($y * 7) + $f * 3) % 14 - 14; $x -lt $w; $x += 14) { $px.Rect($x, $y, 5, 1, $c); $px.Dot($x + 5, $y - 1, $c) } }
  }
  $stage.AddProp('waves', $waves, 0, $hz, 0, 0, 0.35, 1)
  $foam = New-Frames $W 4 4 { param($px, $f) $w = $script:waveArgs[0]; for ($x = 0; $x -lt $w; $x += 6) { $o = ($x / 6 + $f) % 4; $px.Rect($x, $o % 2, 4, 1, '#F0F9FF'); if ($o -lt 2) { $px.Dot($x + 1, 2, '#D0F0F9FF') } } }
  $stage.AddProp('foam', $foam, 0, $seaEnd - 1, 0, 0, 0.3, 2)
  # Nubes que pasan
  $n = switch ($we) { 'clear' { 2 } 'cloudy' { 4 } default { 5 } }
  $cc = switch ($we) { 'clear' { '#F8FAFC' } 'cloudy' { '#CBD5E1' } default { '#64748B' } }
  if ($ph -eq 'night') { $cc = '#334155' }
  $script:cloudCols = Stage-CloudColors $ph $we
  $cl = New-Frames 18 10 1 { param($px, $f) $c = $script:cloudCols; Draw-Cloud $px 1 4 $c[0] $c[1] $c[2] }
  for ($i = 0; $i -lt $n; $i++) {
    $y = 4 + ($i * 7) % [Math]::Max(6, $hz - 12)
    $stage.AddProp("cloud$i", $cl, -20 + $i * 47 % $W, $y, 9, 4, 1, 2)
    $stage.PropPath("cloud$i", [double[]]@(-20, $y, 0, ($W + 20), $y, 0), 1.5 + ($i % 3) * 0.7, $true, $false)
  }
  if ($we -ne 'rain' -and $ph -ne 'night') {
    # Gaviotas
    $gull = New-Frames 7 4 2 { param($px, $f) if ($f) { $px.Glyph(0, 0, '#.....#/.#...#./..#.#..', '#F8FAFC') } else { $px.Glyph(0, 1, '.......#/.##.##./...#...', '#F8FAFC') } }
    foreach ($g in 0, 1) { $y = 6 + $g * 8; $stage.AddProp("gull$g", $gull, $g * 60, $y, 3, 2, 0.25, 6); $stage.PropPath("gull$g", [double[]]@(-10, $y, 0, ($W / 2), ($y + 4), 0, ($W + 10), $y, 0), 10 + $g * 3, $true, $true) }
    # Un velero en el horizonte
    $boat = New-Frames 9 8 2 { param($px, $f) $px.Rect(1, 6 + $f % 2, 7, 2, '#7C2D12'); $px.Rect(4, 0, 1, 6, '#E5E7EB'); $px.Glyph(5, 1, '#./##/###/###', '#F8FAFC') }
    $stage.AddProp('boat', $boat, 60, $hz + 3, 4, 7, 0.8, 1); $stage.PropPath('boat', [double[]]@(-10, ($hz + 3), 0, ($W + 10), ($hz + 3), 0), 1.2, $true, $false)
    # Un pez que salta de vez en cuando
    $fish = New-Frames 7 6 10 { param($px, $f) $pts = @(@(0, 5), @(2, 1), @(5, 3)); if ($f -lt 3) { $p = $pts[$f]; $px.Rect($p[0], $p[1], 3, 2, '#F97316'); $px.Dot($p[0] - 1, $p[1], '#FB923C') } elseif ($f -eq 3) { $px.Dot(5, 5, '#E0F2FE'); $px.Dot(6, 4, '#E0F2FE') } }
    $stage.AddProp('fish', $fish, [int]($W * 0.45), $hz + 9, 0, 0, 0.2, 2)
  }
  # Huellas en la arena y una pelota de playa
  $stage.FootFrame = (New-Frames 2 2 1 { param($px, $f) $px.Rect(0, 0, 2, 2, '#38000000') })[0]
  $stage.FootMinY = $seaEnd + 4
  if (-not ($stage.BallX -ge 0)) { $stage.SetBall((Ball-Frames 'beach'), (($m.Field[0] + $m.Field[2]) / 2), (($m.Field[1] + $m.Field[3]) / 2)) }
  # El cangrejo, de paseo
  $crab = New-Frames 9 5 2 { param($px, $f) $px.Rect(2, 2, 5, 2, '#DC2626'); $px.Dot(3, 1, '#111827'); $px.Dot(5, 1, '#111827'); $px.Rect(0, 1 - $f % 2, 2, 2, '#EF4444'); $px.Rect(7, $f % 2, 2, 2, '#EF4444'); foreach ($lx in 2, 4, 6) { $px.Dot($lx, 4, '#991B1B') } } $true
  $cy = $seaEnd + 12
  $stage.AddProp('crab', $crab, 30, $cy, 4, 4, 0.18, -1)
  $stage.PropPath('crab', [double[]]@(30, $cy, 3, 70, ($cy + 2), 2, 110, $cy, 4, 60, ($cy + 4), 1), 6, $false, $false)
  # Palmeras que se mecen
  $palm = New-Frames 22 34 3 {
    param($px, $f)
    $sw = @(0, 1, 0)[$f]
    for ($y = 12; $y -lt 34; $y++) { $px.Rect(9 + [int]((34 - $y) / 10), $y, 3, 1, $(if ($y % 3) { '#92400E' } else { '#78350F' })) }
    $tx = 11 + $sw; $ty = 11
    foreach ($l in @(@(-10, 4), @(-7, -2), @(0, -5), @(7, -2), @(10, 5))) { $px.Line($tx, $ty, $tx + $l[0] + $sw, $ty + $l[1], '#15803D'); $px.Line($tx, $ty + 1, $tx + $l[0] + $sw, $ty + $l[1] + 1, '#16A34A') }
    $px.Circle($tx, $ty + 1, 1, '#713F12')
  } $true
  $stage.AddProp('palm1', $palm, 6, $seaEnd + 40, 11, 33, 0.6, -1)
  $stage.AddProp('palm2', $palm, ($W - 3), $seaEnd + 44, 11, 33, 0.7, -1)
  if ($we -eq 'rain') { $stage.AddProp('rain', (Rain-Frames $W $H 130), 0, 0, 0, 0, 0.1, 910000) }
  if ($ph -eq 'night' -and $we -eq 'clear') {
    $script:starArgs = @($W, $hz)
    $tw = New-Frames $W $hz 3 { param($px, $f) $r = New-Object System.Random (5 + $f); for ($k = 0; $k -lt 10; $k++) { $px.Dot($r.Next($script:starArgs[0]), $r.Next([int]($script:starArgs[1] * 0.7)), '#FFFFFF') } }
    $stage.AddProp('stars', $tw, 0, 0, 0, 0, 0.5, 1)
  }
  if ($ph -in 'night', 'dusk') {
    if ($ph -eq 'night') {
    # Hoguera con su luz y el faro girando
    $fire = New-Frames 12 12 3 {
      param($px, $f)
      $px.Rect(1, 10, 10, 2, '#78350F'); $px.Line(1, 11, 10, 9, '#92400E')
      $hs = @(@(4, 6, 3, 5), @(5, 4, 6, 3), @(3, 6, 4, 6))[$f]
      for ($i = 0; $i -lt 4; $i++) { $px.Rect(3 + $i * 2, 10 - $hs[$i], 2, $hs[$i], '#F97316'); $px.Rect(3 + $i * 2, 10 - [int]($hs[$i] / 2), 2, [int]($hs[$i] / 2), '#FACC15') }
      $px.Dot(5 + $f, 2, '#FDBA74')
    } $true
    $hs = @($m.Stations | Where-Object { $_.Kind -eq 'hoguera' })
    if ($hs.Count -ge 2) { $bx = [int](($hs[0].X + $hs[1].X) / 2); $by = $hs[0].Y + 2 } else { $bx = [int]($W * 0.3); $by = $wl + [int](0.62 * ($H - $wl - 16)) + 6 }
    $stage.AddProp('fire', $fire, $bx, $by, 6, 11, 0.15, -1)
    Stage-Glow 'fireglow' $bx ($by - 4) 26 '#60FB923C'
    }
    $beam = New-Frames 41 9 4 { param($px, $f) $d = @(1, 0, -1, 0)[$f]; if ($d -ne 0) { for ($i = 1; $i -lt 20; $i++) { $px.Rect(20 + $d * $i, 4 - [int]($i / 6), 1, 1 + [int]($i / 4), '#50FDE68A') } } else { $px.Glow(20, 4, 4, '#90FDE68A') } }
    $stage.AddProp('beam', $beam, $script:stageLight[0], $script:stageLight[1], 20, 4, 0.5, 920000)
  }
}

# Puerta que se abre sola cuando pasa un Claude
function Stage-Door([int]$x, [int]$y, [int]$bottom, [string]$frame, [string]$panel) {
  $script:doorArgs = @(($bottom - $y), $frame, $panel)
  $closed = New-Frames 14 ($bottom - $y) 1 { param($px, $f) $h, $fr, $pn = $script:doorArgs; $px.Rect(0, 0, 14, $h, $fr); $px.Rect(1, 1, 12, $h - 1, $pn); $px.Rect(3, 3, 8, 8, '#5B6575'); $px.Dot(11, [int]($h / 2), '#FACC15') }
  $open = New-Frames 14 ($bottom - $y) 1 { param($px, $f) $h, $fr, $pn = $script:doorArgs; $px.Rect(0, 0, 14, $h, $fr); $px.Rect(1, 1, 12, $h - 1, '#0B0D12'); $px.Gradient(3, 1, 10, $h - 1, '#00FDE68A', '#40FDE68A'); $px.Rect(1, 1, 3, $h - 1, $pn) }
  $d = $script:stageMap.Door
  $stage.AddProp('door', $closed, $d[0], $d[1], $d[0] - $x, $d[1] - $y, 1, 2)
  $stage.PropSensor('door', $open, 16, $false)
}
function Ball-Frames([string]$scen) {
  $script:ballScen = $scen
  New-Frames 7 8 4 {
    param($px, $f)
    $px.Rect(1, 7, 5, 1, '#40000000')
    switch ($script:ballScen) {
      'gym' {
        $px.Circle(3, 3, 3, '#EA580C')
        switch ($f) { 0 { $px.Line(3, 0, 3, 6, '#7C2D12') } 1 { $px.Line(1, 1, 5, 5, '#7C2D12') } 2 { $px.Line(0, 3, 6, 3, '#7C2D12') } 3 { $px.Line(5, 1, 1, 5, '#7C2D12') } }
        $px.Dot(2, 1, '#FDBA74')
      }
      'office' {
        $px.Circle(3, 3, 3, '#FACC15')
        $e = @(@(2, 2), @(3, 2), @(4, 3), @(3, 4))[$f]
        $px.Dot($e[0], $e[1], '#111827'); $px.Dot($e[0] + 2, $e[1], '#111827'); $px.Dot($e[0] + 1, $e[1] + 2, '#B45309')
      }
      default {
        $px.Circle(3, 3, 3, '#F8FAFC')
        $c = '#EF4444', '#3B82F6', '#FACC15', '#22C55E'
        $px.Rect(1, 1, 2, 2, $c[$f % 4]); $px.Rect(4, 1, 2, 2, $c[($f + 1) % 4]); $px.Rect(4, 4, 2, 2, $c[($f + 2) % 4]); $px.Rect(1, 4, 2, 2, $c[($f + 3) % 4])
      }
    }
  } $true
}
# Motas de polvo flotando en los rayos de sol
function Stage-Dust([string]$ph, [string]$we) {
  if ($we -ne 'clear' -or $ph -eq 'night') { return }
  $dust = New-Frames 40 44 4 { param($px, $f) $r = New-Object System.Random 3; for ($k = 0; $k -lt 9; $k++) { $x = $r.Next(40); $y = ($r.Next(44) + $f * 2) % 44; $px.Dot(($x + [int]($y * 0.6)) % 40, $y, '#70FFF7D6') } }
  $i = 0; foreach ($w in $script:stageWins) { $stage.AddProp("dust$i", $dust, $w[0], $stageWall, 0, 0, 0.6, 4); $i++ }
}
$stageDigits = @{ '0' = '###/#.#/#.#/#.#/###'; '1' = '.#./##./.#./.#./###'; '2' = '###/..#/###/#../###'; '3' = '###/..#/###/..#/###'; '4' = '#.#/#.#/###/..#/..#'
  '5' = '###/#../###/..#/###'; '6' = '###/#../###/#.#/###'; '7' = '###/..#/..#/..#/..#'; '8' = '###/#.#/###/#.#/###'; '9' = '###/#.#/###/..#/###' }
function Draw-Num($px, [int]$x, [int]$y, [int]$n, [string]$c, [int]$sc) {
  foreach ($ch in ([string]$n).ToCharArray()) {
    $rows = $stageDigits[[string]$ch].Split('/')
    for ($j = 0; $j -lt 5; $j++) { for ($i = 0; $i -lt 3; $i++) { if ($rows[$j][$i] -eq '#') { $px.Rect($x + $i * $sc, $y + $j * $sc, $sc, $sc, $c) } } }
    $x += 4 * $sc
  }
}
# Marcador del partido: la tele del gimnasio o un cartel en la playa
function Stage-Score {
  $m = $script:stageMap; if (-not $m.Field) { return }
  $script:scoreArgs = @(($stage.ScoreA % 100), ($stage.ScoreB % 100))
  if ($m.Scen -eq 'gym') {
    $fr = New-Frames 30 15 1 {
      param($px, $f)
      $a, $b = $script:scoreArgs
      $px.Gradient(0, 0, 30, 15, '#0B1530', '#14254A'); $px.Rect(1, 1, 28, 1, '#1E3A8A')
      $sc = if ($a -lt 10 -and $b -lt 10) { 2 } else { 1 }
      Draw-Num $px 3 3 $a '#F87171' $sc; $px.Rect(14, 7, 2, 1, '#E5E7EB'); Draw-Num $px 18 3 $b '#60A5FA' $sc
    }
    if ($script:stageTv) { $stage.AddProp('tv', $fr, $script:stageTv[0], $script:stageTv[1], 0, 0, 1, 3) }
  } elseif ($script:matchOn) {
    $fr = New-Frames 24 16 1 {
      param($px, $f)
      $a, $b = $script:scoreArgs
      $px.Rect(4, 9, 1, 7, '#78350F'); $px.Rect(19, 9, 1, 7, '#78350F'); $px.Rect(0, 0, 24, 10, '#92400E'); $px.Rect(1, 1, 22, 8, '#F8FAFC')
      Draw-Num $px 3 3 $a '#DC2626' 1; $px.Rect(11, 5, 2, 1, '#111827'); Draw-Num $px 15 3 $b '#2563EB' 1
    } $true
    $stage.AddProp('score', $fr, $m.Field[2] - 14, $m.Field[1] - 1, 12, 16, 1, -1)
  } else { $stage.RemoveProp('score') }
}
$stage.OnGoal = [Action[int, int, int]]{ param($team, $a, $b) Stage-Score }
$stageMarks = @{}
function Get-Mark([string]$c) {
  if ($stageMarks.ContainsKey($c)) { return $stageMarks[$c] }
  $script:markColor = $c
  $fr = (New-Frames 16 6 1 {
    param($px, $f)
    $c = $script:markColor; $fill = '#60' + $c.TrimStart('#')
    $px.Rect(4, 0, 8, 1, $c); $px.Rect(2, 1, 12, 1, $c); $px.Rect(1, 2, 14, 2, $c); $px.Rect(2, 4, 12, 1, $c); $px.Rect(4, 5, 8, 1, $c)
    $px.Rect(4, 1, 8, 1, $fill); $px.Rect(3, 2, 10, 2, $fill); $px.Rect(4, 4, 8, 1, $fill)
  })[0]
  $stageMarks[$c] = $fr
  $fr
}
# Quién juega: los inactivos que no has dejado en otro sitio, hasta 8; cada uno entra en el equipo con menos gente
function Stage-MatchSync {
  $keys = New-Object System.Collections.Generic.List[int]; $teams = New-Object System.Collections.Generic.List[int]
  if (-not $script:matchOn) {
    foreach ($a in $stageActors.Values) { if ($a.Match) { $a.Match = $false; $a.Kind = '' } }
    $stage.SetMatch($keys.ToArray(), $teams.ToArray()); return
  }
  foreach ($a in $stageActors.Values) { if ($a.Match -and ($a.State -ne 'idle' -or $a.Pinned)) { $a.Match = $false; $a.Kind = '' } }
  $cnt = @(0, 0); foreach ($a in $stageActors.Values) { if ($a.Match) { $cnt[$a.Team]++ } }
  $f = $script:stageMap.Field
  foreach ($a in @($stageActors.Values | Where-Object { $_.State -eq 'idle' -and -not $_.Pinned -and -not $_.Match } | Sort-Object { $_.Pid })) {
    if ($cnt[0] + $cnt[1] -ge 8) { break }
    Stage-Release $a
    $a.Match = $true; $a.Team = $(if ($cnt[0] -le $cnt[1]) { 0 } else { 1 }); $cnt[$a.Team]++; $a.Kind = 'futbol'
    $col = $stageColorOf[$a.Pid]
    $stage.SetPlay($a.Pid, (Get-StageFrames 'walk' '' '' 0 $col 'play'), (Get-StageFrames 'act' 'listo' '' 0 $col 'idle'), (Get-StageFrames 'act' 'gol' '' 0 $col 'idle'))
    if ($a.New) {
      $x = Get-Random -Minimum ($f[0] + 8) -Maximum ($f[2] - 8); $y = Get-Random -Minimum ($f[1] + 6) -Maximum ($f[3])
      $stage.Put($a.Pid, $x, $y, (Get-StageFrames 'act' 'listo' '' 0 $col 'idle'), $false); $a.New = $false
    }
  }
  foreach ($a in $stageActors.Values) { if ($a.Match) { $keys.Add($a.Pid); $teams.Add($a.Team) } }
  $stage.SetMatch($keys.ToArray(), $teams.ToArray())
}
function Stage-ShadeColor([string]$scen, [string]$ph, [string]$we) {
  $out = $scen -eq 'beach'
  if ($ph -eq 'night') { if ($out) { return '#78040A22' } else { return '#46040A22' } }
  if ($we -eq 'rain') { if ($out) { return '#481A2433' } else { return '#261A2433' } }
  if ($we -eq 'cloudy') { if ($out) { return '#2C1A2433' } else { return '#161A2433' } }
  switch ($ph) { 'dawn' { '#2CFF9A5A' } 'dusk' { '#36E8603A' } default { '#00000000' } }
}
# Fondo, decorado vivo y luz del momento; los Claudes no se tocan
function Render-StageScene {
  $m = $script:stageMap
  $ph = Stage-Phase; $we = Stage-Weather
  $script:stageSceneSig = "$($m.Scen)|$($m.W)|$($m.H)|$ph|$we"
  $px = New-Object TaskMon.Pix $m.W, $m.H
  $fx = New-Object TaskMon.Pix $m.W, $m.H
  $script:stageClock = $null
  switch ($m.Scen) { 'gym' { Render-Gym $px $fx $m $ph $we } 'office' { Render-Office $px $fx $m $ph $we } 'beach' { Render-Beach $px $fx $m $ph $we } }
  # Sombras de contacto bajo los muebles (más anchas para los de varios sitios)
  $wide = @{ consola = @(40, 40); podio = @(16, 30); fiesta = @(16, 28); baile = @(16, 28); banco = @(28, 26); fuente = @(28, 22); cafe = @(28, 22); tumbona = @(28, 26); chiringuito = @(26, 26); voley = @(30, 20); hoguera = @(29, 22) }
  foreach ($e in $m.Furn) {
    if ($e[0] -in 'surf', 'cangrejo', 'chapotear', 'castillo') { continue }
    $sw = if ($wide.ContainsKey($e[0])) { $wide[$e[0]] } else { @(16, 13) }
    $px.Ellipse($e[1] + $sw[0], $e[2] + 25, $sw[1], 3, '#38000000')
  }
  foreach ($e in $m.Furn) { Draw-Furn $fx $e[0] $e[1] $e[2] }
  $fx.Outline('#B0101216')
  # El suelo un poco más apagado para que los Claudes resalten
  $px.Rect(0, $stageWall, $m.W, $m.H - $stageWall, '#22000000')
  $px.Blit($fx)
  $script:stageBgImg.Source = $px.ToBitmap()
  $stage.ClearProps(); $stage.ClearFeet(); $stage.FootMinY = 1e9
  $stage.TeamMarks = [System.Windows.Media.Imaging.BitmapSource[]]@((Get-Mark '#EF4444'), (Get-Mark '#3B82F6'))
  $script:stagePhaseNow = $ph
  # Partido: en el gimnasio siempre, en la playa mientras no sea de noche (entonces, a la hoguera)
  $script:matchOn = $m.Field -and -not ($m.Scen -eq 'beach' -and $ph -eq 'night')
  if ($script:matchOn) { $f = $m.Field; $stage.SetField($f[0], $f[1], $f[2], $f[3], $f[4]) } else { $stage.ClearField() }
  $script:stageUmbrella = $m.Scen -eq 'beach' -and $we -eq 'rain'
  switch ($m.Scen) { 'gym' { Props-Gym $m $ph $we } 'office' { Props-Office $m $ph $we } 'beach' { Props-Beach $m $ph $we } }
  $script:stageShade.Fill = Brush (Stage-ShadeColor $m.Scen $ph $we)
  $names = @{ dawn = 'amanecer'; day = 'día'; dusk = 'atardecer'; night = 'noche' }
  $wn = @{ clear = 'despejado'; cloudy = 'nublado'; rain = 'lluvia' }
  $script:stageSky = "$($names[$ph]), $($wn[$we])"
  # Con el cambio, andan con o sin paraguas y dejan los sitios que ya no tocan (la hoguera de día...)
  foreach ($a in $stageActors.Values) {
    $stage.SetWalk($a.Pid, (Get-StageFrames 'walk' '' '' 0 $stageColorOf[$a.Pid] $a.State))
    if ($a.Station -and (($a.Station.N -and $ph -ne 'night') -or ($a.Station.Dy -and $ph -eq 'night'))) { $a.Kind = ''; $a.Pinned = $false }
  }
}

# El mapa: los sitios en píxeles y los muebles que se dibujan en el fondo
function Build-StageMap([string]$scen, [int]$W, [int]$H) {
  $floor = $H - $stageWall - 16
  $stations = New-Object System.Collections.Generic.List[object]
  $furn = New-Object System.Collections.Generic.List[object]
  $g = 0
  foreach ($e in $stageMaps[$scen]) {
    $x = [int][Math]::Round($e.X * $W); $y = $stageWall + 6 + [int][Math]::Round($e.Y * $floor)
    if (-not $e.Dyn) { $furn.Add(@($e.K, ($x - 16), ($y - 25))) }
    $g++
    $seats = @(switch ($e.T) { 'row3' { @(@(0, 0), @(24, 0), @(48, 0)) } 'pair' { @(@(0, 0), @($e.D, 0)) } 'trio' { if ($e.K -eq 'podio') { @(@(0, 0), @(-20, 4), @(20, 7)) } else { @(@(0, 0), @(-20, 0), @(20, 0)) } } default { , @(0, 0) } })
    for ($i = 0; $i -lt $seats.Count; $i++) {
      $stations.Add(@{ Kind = $e.K; X = $x + $seats[$i][0]; Y = $y + $seats[$i][1]; State = $e.S; Seat = $i; Group = $(if ($e.T -eq 'pair') { $g } else { 0 }); Occ = 0; E = [bool]$e.E; N = [bool]$e.N; Dy = [bool]$e.Dy; Dyn = [bool]$e.Dyn })
    }
  }
  # Al frente, mirando a la pantalla, los que te esperan
  foreach ($nx in 0.14, 0.38, 0.62, 0.86) { $stations.Add(@{ Kind = 'frente'; X = [int]($nx * $W); Y = $H - 10; State = 'waiting'; Seat = 0; Group = 0; Occ = 0 }) }
  $d = $stageDoor[$scen]
  $field = $null
  if ($stageFields.ContainsKey($scen)) {
    $fd = $stageFields[$scen]
    $field = @(([int]($fd[0] * $W)), ($stageWall + 6 + [int]($fd[1] * $floor)), ([int]($fd[2] * $W)), ($stageWall + 6 + [int]($fd[3] * $floor)), 12)
  }
  @{ Scen = $scen; W = $W; H = $H; Stations = $stations; Furn = $furn; Field = $field; Door = @(([int]($d[0] * $W) + 8), ($stageWall + 6 + [int]($d[1] * $floor))) }
}

function Stage-Release($a) { if ($a.Station) { $a.Station.Occ = 0; $a.Station = $null } }
# Un sitio libre para su estado: los de dos, mejor si ya hay alguien igual con quien hablar; el podio, por orden de llegada
function Stage-Pick([string]$state) {
  $night = $script:stagePhaseNow -eq 'night'
  $free = @($script:stageMap.Stations | Where-Object { $_.State -eq $state -and $_.Occ -eq 0 -and -not ($_.N -and -not $night) -and -not ($_.Dy -and $script:stagePhaseNow -eq 'night') })
  if (-not $free.Count) { return $null }
  $best = @(); $top = -1
  foreach ($s in $free) {
    $score = 0
    if ($s.Group) {
      $mate = $script:stageMap.Stations | Where-Object { $_.Group -eq $s.Group -and $_.Seat -ne $s.Seat } | Select-Object -First 1
      if ($mate.Occ -and $stageActors[$mate.Occ].State -eq $state) { $score = 2 }
    }
    if ($s.Kind -in 'podio', 'fiesta', 'baile') { $score = 3 - $s.Seat }
    if ($s.E) { $score = Get-Random -Maximum 3 }
    if ($score -gt $top) { $top = $score; $best = @($s) } elseif ($score -eq $top) { $best += $s }
  }
  $best[(Get-Random -Maximum $best.Count)]
}
# Un hueco en el suelo cerca de los suyos (o donde sea), sin pisar a nadie
function Stage-Spot([string]$state) {
  $m = $script:stageMap
  $near = @($m.Stations | Where-Object { $_.State -eq $state })
  for ($try = 0; $try -lt 25; $try++) {
    if ($state -eq 'waiting') { $x = Get-Random -Minimum 12 -Maximum ($m.W - 12); $y = $m.H - 10 }
    elseif ($near.Count -and $state -ne 'unknown') { $s = $near[(Get-Random -Maximum $near.Count)]; $x = $s.X + (Get-Random -Minimum -30 -Maximum 31); $y = $s.Y + (Get-Random -Minimum -4 -Maximum 16) }
    else { $x = Get-Random -Minimum 12 -Maximum ($m.W - 12); $y = Get-Random -Minimum ($stageWall + 14) -Maximum ($m.H - 14) }
    $x = [Math]::Max(10, [Math]::Min($m.W - 10, $x)); $y = [Math]::Max($stageWall + 8, [Math]::Min($m.H - 10, $y))
    $ok = $true
    foreach ($o in $stageActors.Values) { if ([Math]::Abs($o.X - $x) -lt 14 -and [Math]::Abs($o.Y - $y) -lt 10) { $ok = $false; break } }
    foreach ($s in $m.Stations) { if ($s.Occ -and [Math]::Abs($s.X - $x) -lt 14 -and [Math]::Abs($s.Y - $y) -lt 10) { $ok = $false; break } }
    if ($ok) { break }
  }
  @($x, $y)
}
# Mandarle a un sitio con la actividad que toca
function Stage-Send($a, [double]$x, [double]$y, [string]$kind, [int]$seat) {
  $a.X = $x; $a.Y = $y; $a.Kind = $kind; $a.Seat = $seat
  $frames = Get-StageFrames 'act' $kind $a.Variant $seat $stageColorOf[$a.Pid] $a.State
  $slow = $a.State -in 'idle', 'paused'
  if ($a.New) { $stage.Put($a.Pid, $x, $y, $frames, $slow); $a.New = $false }
  else { $stage.Go($a.Pid, $x, $y, $frames, $slow, $(if ($a.State -eq 'busy') { 18 } elseif ($a.State -eq 'done') { 14 } else { 10 })) }
  $stage.SetBlink($a.Pid, (Get-StageFrames 'blink' $kind $a.Variant $seat $stageColorOf[$a.Pid] $a.State))
}
function Stage-Decide($a, [string]$st, [int]$now) {
  $changed = $a.State -ne $st
  $was = $a.State
  $a.State = $st
  if ($changed) { $a.Match = $false }
  # Los inactivos juegan el partido (si cabe y no los has dejado en otro sitio)
  if ($st -eq 'idle' -and $script:matchOn -and -not $a.Pinned -and ($a.Match -or @($stageActors.Values | Where-Object { $_.Match }).Count -lt 8)) {
    if ($changed) { $stage.SetWalk($a.Pid, (Get-StageFrames 'walk' '' '' 0 $stageColorOf[$a.Pid] $st)); $stage.SetMoods($a.Pid, (Get-Moods $st)) }
    return
  }
  if ($changed) {
    # Su forma de andar y lo que le sale por la cabeza dependen de cómo está
    $col = $stageColorOf[$a.Pid]
    $stage.SetWalk($a.Pid, (Get-StageFrames 'walk' '' '' 0 $col $st))
    $stage.SetMoods($a.Pid, (Get-Moods $st))
    if ($was) {
      switch ($st) {
        'done' {
          # Termina uno: él lo celebra y los demás le aplauden
          $stage.Emote($a.Pid, (Get-Emote 'star'), 3)
          $mx = $stage.GetX($a.Pid); $my = $stage.GetY($a.Pid)
          $near = @($stageActors.Values | Where-Object { $_.Pid -ne $a.Pid -and $_.State -ne 'resuming' } | Sort-Object { [Math]::Abs($stage.GetX($_.Pid) - $mx) + [Math]::Abs($stage.GetY($_.Pid) - $my) } | Select-Object -First 3)
          foreach ($o in $near) { $stage.Emote($o.Pid, (Get-Emote $(if ($o.State -eq 'busy') { 'clap' } else { 'heart' })), 2.5) }
        }
        'error'   { $stage.Emote($a.Pid, (Get-Emote 'anger'), 3) }
        'waiting' { $stage.Emote($a.Pid, (Get-Emote 'excl'), 2.5) }
        'busy'    { $stage.Emote($a.Pid, (Get-Emote 'idea'), 2.5) }
        'paused'  { $stage.Emote($a.Pid, (Get-Emote 'snow'), 2.5) }
      }
    }
  }
  # En pausa se congela donde esté; al reanudar se descongela ahí mismo
  if ($st -in 'paused', 'resuming') {
    if ($changed) {
      Stage-Release $a; $a.Pinned = $false; $a.Variant = 'solo'
      $pt = if ($a.New) { Stage-Spot $st } else { @($stage.GetX($a.Pid), $stage.GetY($a.Pid)) }
      Stage-Send $a $pt[0] $pt[1] $stagePortable[$st] 0
    }
    return
  }
  if ($a.Pinned -and -not $changed) { return }
  $a.Pinned = $false
  $keep = -not $changed -and $a.Kind
  if ($keep) {
    $age = $now - $a.Since
    if (-not $a.Station -and (Stage-Pick $st)) { $keep = $false }                                       # se ha quedado libre un sitio para él
    elseif ($a.Station -and $a.Station.E -and $age -gt 15000 -and (Get-Random -Maximum 100) -lt 50) { $keep = $false }   # acaba el recado
    elseif ($st -in 'idle', 'done' -and $age -gt 25000 -and (Get-Random -Maximum 100) -lt 30) { $keep = $false }   # se da una vuelta
    elseif ($st -eq 'busy' -and $age -gt 90000 -and (Get-Random -Maximum 100) -lt 20) { $keep = $false }           # cambia de máquina
    elseif ($st -eq 'unknown' -and $age -gt 12000 -and (Get-Random -Maximum 100) -lt 50) { $keep = $false }
  }
  if ($keep) { return }
  Stage-Release $a
  $a.Since = $now; $a.Variant = 'solo'
  $s = Stage-Pick $st
  if ($s) { $s.Occ = $a.Pid; $a.Station = $s; Stage-Send $a $s.X $s.Y $s.Kind $s.Seat }
  else { $pt = Stage-Spot $st; Stage-Send $a $pt[0] $pt[1] $stagePortable[$st] 0 }
}
# Los que comparten banco, sofá o red con otro igual que ellos hablan (o se pasan la pelota)
function Stage-Variants {
  foreach ($a in $stageActors.Values) {
    if ($a.Match) { continue }
    $v = 'solo'
    if ($a.Station -and $a.Station.Group) {
      $mate = $script:stageMap.Stations | Where-Object { $_.Group -eq $a.Station.Group -and $_.Seat -ne $a.Station.Seat } | Select-Object -First 1
      if ($mate.Occ -and $stageActors[$mate.Occ].State -eq $a.State) { $v = 'chat' }
    }
    if ($v -ne $a.Variant) { $a.Variant = $v; Stage-Send $a $a.X $a.Y $a.Kind $a.Seat }
  }
}
function New-StageTag($it, [int]$p) {
  $tag = New-Object System.Windows.Controls.Border
  $tag.CornerRadius = [System.Windows.CornerRadius]::new(1.2); $tag.Background = Brush '#C0101216'; $tag.Padding = '1,0.2,1.2,0.2'; $tag.DataContext = $it; $tag.Cursor = 'Hand'
  $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
  $bar = New-Object System.Windows.Shapes.Rectangle; $bar.Width = 1.2; $bar.Height = 3; $bar.Margin = '0,0,1,0'; $bar.Fill = Brush $stageAccents[$stageColorOf[$p]]
  $tb = New-Object System.Windows.Controls.TextBlock; $tb.FontSize = 3; $tb.Foreground = Brush '#F1F5F9'; $tb.MaxWidth = 24; $tb.TextTrimming = 'CharacterEllipsis'
  [void]$sp.Children.Add($bar); [void]$sp.Children.Add($tb); $tag.Child = $sp
  @{ Tag = $tag; Text = $tb }
}

function Update-Stage([bool]$force) {
  $scen = [string]$settings.stage; if (-not $stageNames.Contains($scen)) { $scen = 'gym' }
  $pw = $ui.StageArea.ActualWidth; $ph = $ui.StageArea.ActualHeight
  if ($pw -lt 60 -or $ph -lt 60) { return }
  $W = [int][Math]::Floor($pw / $stagePx); $H = [int][Math]::Floor($ph / $stagePx)
  $m = $script:stageMap
  if ($force -or -not $m -or $m.Scen -ne $scen -or $m.W -ne $W -or $m.H -ne $H) {
    # Mapa nuevo: todos aparecen ya en su sitio
    $stage.Clear(); $stageActors.Clear(); $stageFrames.Clear()
    $stage.ClearProps(); $stage.ClearBall()
    $script:stageMap = Build-StageMap $scen $W $H
    $cv = $ui.StageCanvas; $cv.Children.Clear(); $cv.Width = $W; $cv.Height = $H
    $script:stageBgImg = New-Object System.Windows.Controls.Image; $script:stageBgImg.Width = $W; $script:stageBgImg.Height = $H
    [System.Windows.Controls.Panel]::SetZIndex($script:stageBgImg, -1); [void]$cv.Children.Add($script:stageBgImg)
    # Luz del momento (amanecer, atardecer, noche, nubes) por encima de todo menos las luces y las etiquetas
    $script:stageShade = New-Object System.Windows.Shapes.Rectangle; $script:stageShade.Width = $W; $script:stageShade.Height = $H; $script:stageShade.IsHitTestVisible = $false
    [System.Windows.Controls.Panel]::SetZIndex($script:stageShade, 900000); [void]$cv.Children.Add($script:stageShade)
    $script:stageSceneSig = ''
    if (-not $stage.GreetFrames) { $stage.GreetFrames = Get-Emote 'hi'; $stage.ScaredFrames = Get-Emote 'scared'; $stage.DizzyFrames = Get-Emote 'dizzy'; $stage.BallHitFrames = Get-Emote 'excl' }
    $stage.MinX = 8; $stage.MaxX = $W - 8; $stage.MinY = $stageWall + 6; $stage.MaxY = $H - 8
    $fresh = $true
  } else { $fresh = $false }
  $m = $script:stageMap
  # El fondo cambia con la hora del día y el tiempo; el reloj, cada minuto
  if ("$($m.Scen)|$($m.W)|$($m.H)|$(Stage-Phase)|$(Stage-Weather)" -ne $script:stageSceneSig) { Render-StageScene }
  elseif ($script:stageClock -and (Get-Date).Minute -ne $script:clockMinute) { Stage-Clock }
  $all = @($items | Sort-Object @{ e = { [int]$_['Pid'] } })
  # Los pausados no están en el escenario: si estaba, se despide y sale por la puerta
  $list = @($all | Where-Object { [string]$_['State'] -ne 'paused' })
  $pausedN = $all.Count - $list.Count
  $live = @{}; foreach ($it in $list) { $live[[int]$it['Pid']] = $true }
  $exists = @{}; foreach ($it in $all) { $exists[[int]$it['Pid']] = $true }
  foreach ($k in @($stageActors.Keys)) {
    if ($live.ContainsKey($k)) { continue }
    $a = $stageActors[$k]; Stage-Release $a
    if ($exists.ContainsKey($k)) { $stage.Emote($k, (Get-Emote 'zzz'), 3); $stage.Leave($k, $m.Door[0], $m.Door[1], (Get-StageFrames 'walk' '' '' 0 $stageColorOf[$k] 'idle')) } else { $stage.Remove($k) }
    $stageActors.Remove($k)
  }
  foreach ($s in $m.Stations) {
    if ($s.Kind -eq 'chuta' -and $stage.BallX -ge 0) { $s.X = [Math]::Max(10, $stage.BallX - 8); $s.Y = $stage.BallY + 1 }
    elseif ($s.Kind -eq 'acaricia' -and $stage.PropX('cat') -ge 0) { $s.X = [Math]::Max(10, $stage.PropX('cat') - 10); $s.Y = $stage.PropY('cat') }
  }
  foreach ($k in @($stageColorOf.Keys)) { if (-not $live.ContainsKey($k)) { $stageColorOf.Remove($k) } }
  # Cada Claude conserva su color mientras viva; se reparten sin repetir mientras haya
  foreach ($it in $list) {
    $p = [int]$it['Pid']
    if ($stageColorOf.ContainsKey($p)) { continue }
    $taken = @($stageColorOf.Values)
    $free = @(0..($stageAccents.Count - 1) | Where-Object { $taken -notcontains $_ })
    $stageColorOf[$p] = $(if ($free.Count) { $free[0] } else { $p % $stageAccents.Count })
  }
  $now = [Environment]::TickCount
  foreach ($it in $list) {
    $p = [int]$it['Pid']; $st = [string]$it['State']; if (-not $stateInfo.ContainsKey($st)) { $st = 'unknown' }
    $a = $stageActors[$p]
    if (-not $a) {
      # Los nuevos entran por la puerta (o aparecen en su sitio si el mapa es nuevo)
      $t = New-StageTag $it $p
      $a = @{ Pid = $p; State = ''; Station = $null; Pinned = $false; Since = $now; Variant = 'solo'; Kind = ''; Seat = 0; X = 0; Y = 0; New = $fresh; Tag = $t.Tag; Text = $t.Text }
      $stageActors[$p] = $a
      $stage.Add($p, $it, $t.Tag, (Get-StageFrames 'walk' '' '' 0 $stageColorOf[$p] $st), (Get-StageFrames 'drag' '' '' 0 $stageColorOf[$p] $st), $m.Door[0], $m.Door[1])
      $stage.SetMark($p, (Get-Mark $stageAccents[$stageColorOf[$p]])); $stage.SetLand($p, (Get-StageFrames 'land' '' '' 0 $stageColorOf[$p] $st))
    }
    Stage-Decide $a $st $now
  }
  Stage-MatchSync
  Stage-Variants
  $count = [ordered]@{}
  foreach ($it in $list) {
    $p = [int]$it['Pid']; $a = $stageActors[$p]; if (-not $a) { continue }
    $title = [string]$it['Title']
    $a.Text.Text = $title
    $label = $stateInfo[$a.State].Label
    $doing = if ($a.Match) { "jugando al fútbol (equipo $(if ($a.Team) { 'azul' } else { 'rojo' }))" } else { "$(if ($stage.IsWalking($p)) { 'de camino: ' })$($stageText[$a.Kind])" }
    $tip = "$title`n$label · $doing`nPulsa para ver su tarea · arrástralo para moverlo"
    $img = $stage.GetImage($p); if ($img) { $img.ToolTip = $tip }; $a.Tag.ToolTip = $tip
    $l = $label.ToLower(); $count[$l] = 1 + [int]$count[$l]
  }
  $parts = @($count.Keys | ForEach-Object { "$($count[$_]) $_" })
  $ui.StageSummary.Text = "$($list.Count) $(if ($list.Count -eq 1) { 'Claude' } else { 'Claudes' })$(if ($parts.Count) { ' · ' + ($parts -join ' · ') })$(if ($pausedN) { " · $pausedN en pausa (fuera)" })$(if ($script:matchOn) { " · partido $($stage.ScoreA)-$($stage.ScoreB)" }) · $script:stageSky"
  if ($ui.StageBtn.IsChecked -and $window.WindowState -ne 'Minimized') { $stage.Start() }
}
# Soltar uno: si cae junto a un sitio libre que le vale, lo usa; si no, se queda ahí haciendo lo suyo hasta que cambie de estado
$stage.OnDrop = [Action[int, double, double]]{
  param($k, $x, $y)
  $a = $stageActors[$k]; if (-not $a) { return }
  Stage-Release $a
  $a.Since = [Environment]::TickCount; $a.Variant = 'solo'; $a.Match = $false; $a.Pinned = $true
  # Un inactivo soltado en el campo vuelve al partido
  $f = $script:stageMap.Field
  if ($a.State -eq 'idle' -and $script:matchOn -and $x -ge $f[0] -and $x -le $f[2] -and $y -ge $f[1] -and $y -le $f[3] + 4) { $a.Pinned = $false; Stage-MatchSync; return }
  # Si no, va al ordenador, máquina o sitio libre de lo suyo más cercano a donde lo dejaste
  $best = $null; $bd = 1e9
  if ($a.State -notin 'paused', 'resuming') {
    foreach ($s in $script:stageMap.Stations) {
      if ($s.Occ -or $s.State -ne $a.State -or $s.Dyn) { continue }
      if ($s.N -and $script:stagePhaseNow -ne 'night') { continue }
      $d = [Math]::Sqrt(($s.X - $x) * ($s.X - $x) + ($s.Y - $y) * ($s.Y - $y))
      if ($d -lt $bd) { $bd = $d; $best = $s }
    }
  }
  if ($best) { $best.Occ = $k; $a.Station = $best; Stage-Send $a $best.X $best.Y $best.Kind $best.Seat }
  else { Stage-Send $a $x $y $stagePortable[$a.State] 0 }
  Stage-MatchSync
  Stage-Variants
}
foreach ($k in $stageNames.Keys) { Add-Option $ui.StageOpts 'stage' $k $stageNames[$k] }
# Clic derecho en un Claude (o su nombre) abre su ficha, la misma que en su tarjeta; el izquierdo solo arrastra
$ui.StageCanvas.AddHandler([System.Windows.UIElement]::PreviewMouseRightButtonUpEvent, $onCardMenu)
$ui.StageArea.Add_SizeChanged({ if ($ui.StageBtn.IsChecked) { Update-Stage $false } })
$onStage = {
  $open = [bool]$ui.StageBtn.IsChecked
  if ($open) { $ui.SettingsBtn.IsChecked = $false; $ui.DiaryBtn.IsChecked = $false }
  $ui.StagePanel.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
  $ui.TitleCmd.Text = $(if ($open) { 'stage' } elseif ($ui.DiaryBtn.IsChecked) { 'diary' } elseif ($ui.SettingsBtn.IsChecked) { 'config --edit' } else { 'watch' })
  if ($open) { Update-Stage $false } else { Release-Stage }
  Apply-Sprites
}
function Release-Stage {
  $stage.Stop(); $stage.Clear(); $stage.ClearProps(); $stage.ClearBall(); $stage.ClearFeet(); $stage.ClearField()
  $ui.StageCanvas.Children.Clear()
  $stageActors.Clear(); $stageFrames.Clear(); $stageMarks.Clear()
  foreach ($s in @($stageEmotes.Keys)) { if ($s -notin 'hi', 'scared', 'dizzy', 'excl') { $stageEmotes.Remove($s) } }
  $script:stageMap = $null; $script:stageBgImg = $null; $script:stageShade = $null; $script:stageSceneSig = ''
  Trim-Soon
}
$ui.StageBtn.Add_Checked($onStage); $ui.StageBtn.Add_Unchecked($onStage)
$ui.StageDone.Add_Click({ $ui.StageBtn.IsChecked = $false })
$ui.StageBack.Add_Click({ $ui.StageBtn.IsChecked = $false })

$tick = 0
$stateSince = @{}      # pid -> @{ State; Since; SawWork }: desde cuándo está en su estado
$startDirs = @{}       # pid -> carpeta en la que se lanzó claude (donde se hizo el cd)
$sessionCache = @{}    # archivo -> @{ Time; Data }: cada JSON se lee solo cuando cambia
$usage = $null
$usageTime = [datetime]::MinValue
$slotsSig = ''
$aliveFile = Join-Path $dataDir 'alive'
[void][TaskMon.Native]::CpuPercent()

# Cada estado tiene su color, fijo en todos los estilos, para que no se confundan entre sí
$stateInfo = @{
  busy     = @{ Label = 'EN CURSO';   Verb = 'trabajando desde hace';    Color = '#4D9BFF' }
  waiting  = @{ Label = 'ESPERANDO';  Verb = 'esperándote desde hace';   Color = '#FF9F43' }
  done     = @{ Label = 'LISTO';      Verb = 'terminó hace';             Color = '#2ED47A' }
  idle     = @{ Label = 'INACTIVA';   Verb = 'sin actividad desde hace'; Color = '#8C96A8' }
  error    = @{ Label = 'ERROR';      Verb = 'se detuvo hace';           Color = '#FF5470' }
  paused   = @{ Label = 'EN PAUSA';   Verb = 'en pausa desde hace';      Color = '#E879F9' }
  resuming = @{ Label = 'REANUDANDO'; Verb = 'reanudando';               Color = '#A78BFA' }
  unknown  = @{ Label = 'SIN DATOS';  Verb = '';                         Color = '#5F6775' }
}
$idleAfterMs = 30 * 60000   # un LISTO sin tocar durante 30 min pasa a INACTIVA
function State-Color([string]$state) { $stateInfo[$state].Color }

function Read-Json-Cached([string]$path) {
  $time = [IO.File]::GetLastWriteTimeUtc($path)
  $c = $sessionCache[$path]
  if ($c -and $c.Time -eq $time) { return $c.Data }
  $data = $null
  try { $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch {}
  if ($data) { $sessionCache[$path] = @{ Time = $time; Data = $data } }
  $data
}

# Sesiones que el mod ha anotado, por pid de claude.exe; borra las que terminaron
function Read-Sessions($alive) {
  $byPid = @{}
  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  foreach ($path in [IO.Directory]::GetFiles($sessionDir, '*.json')) {
    $s = Read-Json-Cached $path
    if (-not $s) { continue }   # a medio escribir: se lee en la próxima vuelta
    $pidFile = [IO.Path]::ChangeExtension($path, '.pid')
    $procId = [int]$s.pid
    if (-not $procId -and [IO.File]::Exists($pidFile)) { $procId = [int]([IO.File]::ReadAllText($pidFile).Trim()) }
    $age = $nowMs - [long]$s.updated
    if ($s.state -eq 'ended' -or ($procId -and -not $alive.ContainsKey($procId) -and $age -gt 60000) -or (-not $procId -and $age -gt 86400000)) {
      Remove-Item -LiteralPath $path, $pidFile -Force
      $sessionCache.Remove($path)
      continue
    }
    if (-not $procId -or -not $alive.ContainsKey($procId)) { continue }
    if (-not $byPid.ContainsKey($procId) -or [long]$byPid[$procId].updated -lt [long]$s.updated) { $byPid[$procId] = $s }
  }
  $byPid
}

# Título de la ventana de terminal. Claude pone delante ✳ cuando está libre y un spinner (◐ ◓ ⠂...) cuando trabaja.
$idleMark = [string][char]0x2733
function Window-Title([int]$procId) {
  $raw = [TaskMon.Native]::ConsoleTitle($procId)
  if (-not $raw) { return $null }
  $mark = if ($raw -match '^([^\p{L}\p{N}\s]+)') { $Matches[1] } else { '' }
  $activity = if (-not $mark) { '' } elseif ($mark.Contains($idleMark)) { 'idle' } else { 'busy' }
  $text = ($raw -replace '^[^\p{L}\p{N}]+', '').Trim()
  if ($text -match '\.exe$' -or $text -match '^(Administrador|Administrator):') { $text = $null }
  @{ Text = $text; Activity = $activity }
}

function Format-Left([TimeSpan]$t) {
  if ($t.TotalMinutes -lt 1) { 'menos de 1 min' }
  elseif ($t.TotalHours -lt 1) { '{0} min' -f [int][Math]::Floor($t.TotalMinutes) }
  elseif ($t.TotalDays -lt 1) { '{0}h {1:00}m' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
  else { '{0}d {1}h' -f [int][Math]::Floor($t.TotalDays), $t.Hours }
}

# Uso de Claude (semanal y de 5 horas): lo escribe el mod en usage.json tras cada respuesta
function Update-Usage {
  $f = Join-Path $dataDir 'usage.json'
  if ([IO.File]::Exists($f)) {
    $time = [IO.File]::GetLastWriteTimeUtc($f)
    if ($time -ne $script:usageTime) {
      try { $script:usage = [IO.File]::ReadAllText($f) | ConvertFrom-Json; $script:usageTime = $time } catch {}
    }
  }
  $notes = @()
  foreach ($w in @(@{ Kind = 'seven_day'; Text = $ui.WeekText; Scale = $ui.WeekScale; Bar = $ui.WeekBar; Name = 'Semana' }, @{ Kind = 'five_hour'; Text = $ui.FiveText; Scale = $ui.FiveScale; Bar = $ui.FiveBar; Name = '5 h' })) {
    $l = if ($script:usage) { @($script:usage.limits) | Where-Object { $_.kind -eq $w.Kind } | Select-Object -First 1 }
    if (-not $script:usage) { $w.Text.Text = '--'; $w.Text.Foreground = $theme.Dim; $w.Scale.ScaleX = 0; continue }
    # Una ventana que ya se reinició (o que Claude deja de enviar tras reiniciarse) empieza de cero
    $left = if ($l -and $l.resetsAt) { [DateTimeOffset]::Parse([string]$l.resetsAt) - [DateTimeOffset]::Now } else { $null }
    $pct = if ($l -and ($null -eq $left -or $left.TotalSeconds -gt 0)) { [double]$l.percent } else { 0.0 }
    $color = Level-Color $pct
    $w.Text.Text = '{0:N0}%' -f $pct
    $w.Text.Foreground = Brush-Cached $color
    $w.Bar.Background = Brush-Cached $color
    $w.Scale.ScaleX = [Math]::Min(1.0, [Math]::Max(0.0, $pct / 100))
    if ($left -and $left.TotalSeconds -gt 0) { $notes += "$($w.Name): se reinicia en $(Format-Left $left)" } else { $notes += "$($w.Name): ventana nueva" }
  }
  $ui.UsagePanel.ToolTip = if (-not $script:usage) { 'Uso de Claude: aparece tras la próxima respuesta en una sesión abierta con esta versión del mod.' }
    else { ($notes -join '   ·   ') + "   ·   leído hace $(Format-Ago (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) - [long]$script:usage.updated))" }
}

function Refresh {
  $now = Get-Date
  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

  # Totales del sistema (llamadas nativas: nada de WMI)
  $mem = [TaskMon.Native]::Memory()
  $totalMB = $mem[0]
  $freeMB = $mem[1]
  $usedMB = $totalMB - $freeMB
  $ramPct = $usedMB / $totalMB * 100
  $cpuPct = [TaskMon.Native]::CpuPercent()
  $prevCpuPct = if ($script:cpuHistory.Count) { $script:cpuHistory[$script:cpuHistory.Count - 1] } else { $cpuPct }
  $prevRamPct = if ($script:ramHistory.Count) { $script:ramHistory[$script:ramHistory.Count - 1] } else { $ramPct }
  Push $script:cpuHistory $cpuPct $historyLen
  Push $script:ramHistory $ramPct $historyLen

  # Mismo criterio en todos los estilos: verde < 70 %, amarillo 70-90 %, rojo desde 90 %
  $ramLevel = Level $ramPct
  $cpuColor = Level-Color $cpuPct
  $ramColor = Level-Color $ramPct
  $fmt = if ($settings.style -eq 'hacker') { '{0:000}%' } elseif ($settings.style -eq 'trading') { '{0:N1}%' } else { '{0:N0}%' }
  $ui.CpuText.Text = $fmt -f $cpuPct; $ui.RamText.Text = $fmt -f $ramPct
  $ui.CpuText.Foreground = Brush-Cached $cpuColor; $ui.RamText.Foreground = Brush-Cached $ramColor
  $ui.CpuGlow.Color = Color $cpuColor; $ui.RamGlow.Color = Color $ramColor
  $ui.CpuSide.Text = "$cores núcleos"
  $ui.RamSide.Text = '{0:N1} / {1:N1} GB' -f ($usedMB / 1024), ($totalMB / 1024)
  if ($style.Delta) {
    foreach ($pair in @(@($ui.CpuDelta, ($cpuPct - $prevCpuPct)), @($ui.RamDelta, ($ramPct - $prevRamPct)))) {
      $d = [double]$pair[1]
      $pair[0].Text = $(if ($d -ge 0) { '▲ +{0:N1}' -f $d } else { '▼ {0:N1}' -f $d })
      $pair[0].Foreground = $(if ($d -ge 0) { $up } else { $down })
    }
  }
  if ($style.Stats -or $style.Delta) {
    foreach ($pair in @(@($ui.CpuStats, $script:cpuHistory), @($ui.RamStats, $script:ramHistory))) {
      $m = $pair[1] | Measure-Object -Minimum -Maximum -Average
      $pair[0].Text = $(if ($settings.style -eq 'trading') { 'mín {0:N1}  máx {1:N1}  apertura {2:N1}' -f $m.Minimum, $m.Maximum, $pair[1][0] } else { 'mín {0:N0}%  ·  media {1:N0}%  ·  máx {2:N0}%' -f $m.Minimum, $m.Average, $m.Maximum })
    }
  }
  if ($ramLevel -eq 2) { $ui.Frame.BorderBrush = '#7A1F30' } else { $ui.Frame.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Line') }
  Draw-Graph 'cpu' $ui.CpuCanvas $ui.CpuLine $ui.CpuArea $ui.CpuDots $ui.CpuHead $script:cpuHistory $cpuColor
  Draw-Graph 'ram' $ui.RamCanvas $ui.RamLine $ui.RamArea $ui.RamDots $ui.RamHead $script:ramHistory $ramColor
  $ui.Ticker.Text = 'CPU {0:N1} {1}   RAM {2:N1} {3}' -f $cpuPct, $(if ($cpuPct -ge $prevCpuPct) { '▲' } else { '▼' }), $ramPct, $(if ($ramPct -ge $prevRamPct) { '▲' } else { '▼' })

  # Árbol de procesos: una sola llamada al sistema
  $procs = [TaskMon.Native]::Snapshot()
  $tree = New-Object TaskMon.Tree (, $procs)
  $byId = $tree.ById; $children = $tree.Children
  $isCli = { param($p) $p -and $p.Name -eq 'claude.exe' -and [TaskMon.Native]::ImagePath($p.Pid, $p.Created) -notmatch 'AnthropicClaude|WindowsApps' }
  $roots = @($tree.Claude | Where-Object { (& $isCli $_) -and -not (& $isCli $byId[$_.Ppid]) })

  $rootSet = @{}; foreach ($r in $roots) { $rootSet[$r.Pid] = $true }
  $inTree = @{}
  $sessions = Read-Sessions $byId
  $elapsed = if ($script:prevTime) { ($now - $script:prevTime).TotalSeconds } else { 0 }
  $nextCpu = @{}
  $script:treeOf = @{}
  $raw = foreach ($r in $roots) {
    $rootId = $r.Pid
    $stack = New-Object System.Collections.Generic.Stack[int]; $stack.Push($rootId)
    $memMB = 0.0; $cpuSec = 0.0; $procCount = 0; $treePids = New-Object System.Collections.Generic.List[int]
    while ($stack.Count) {
      $id = $stack.Pop()
      if ($id -eq $PID -or $inTree.ContainsKey($id) -or ($id -ne $rootId -and $rootSet.ContainsKey($id))) { continue }
      $p = $byId[$id]; if (-not $p) { continue }
      $inTree[$id] = $true
      # La consola (conhost) no se congela: si se congelara, la ventana de la sesión dejaría de responder
      if ($p.Name -notin 'conhost.exe', 'OpenConsole.exe') { $treePids.Add($id) }
      $procCount++
      $memMB += $p.WorkingSet / 1MB
      $cpuSec += $p.CpuTime / 1e7
      if ($children.ContainsKey($id)) { foreach ($c in $children[$id]) { $stack.Push($c) } }
    }
    $script:treeOf[$rootId] = $treePids.ToArray()
    $nextCpu[$rootId] = $cpuSec
    $taskCpu = if ($elapsed -gt 0 -and $script:prevCpu.ContainsKey($rootId)) { [Math]::Max(0.0, ($cpuSec - $script:prevCpu[$rootId]) / $elapsed / $cores * 100) } else { 0.0 }
    $s = $null
    foreach ($id in $treePids) { if ($sessions.ContainsKey($id)) { $s = $sessions[$id]; break } }
    [pscustomobject]@{ Pid = $rootId; Mem = $memMB; Cpu = $taskCpu; Procs = $procCount; Created = $r.Created; Session = $s; Window = $(if ($paused.ContainsKey($rootId)) { $null } else { Window-Title $rootId }) }
  }
  $script:prevCpu = $nextCpu
  $script:prevTime = $now

  # una sesión pausada que ya no existe: lo que colgaba de ella (Blender en espera, bash, mcp...) se descongela, no se queda huérfano
  foreach ($k in @($paused.Keys)) { if (-not ($raw | Where-Object Pid -eq $k)) { Thaw-Pids $paused[$k].pids; $paused.Remove($k); Save-Paused } }

  # Procesos congelados desde la pestaña Render (vídeos de FORJA en pausa): sus sesiones salen EN PAUSA
  $renderFrozen = New-Object 'System.Collections.Generic.HashSet[int]'
  if ($renderStore) { foreach ($v in @($renderStore.paused.Values)) { foreach ($x in @($v.pids)) { [void]$renderFrozen.Add([int]$x) } } }
  # Tarjetas: se actualizan en sitio para no perder la edición ni el scroll
  $seen = @{}
  foreach ($t in $raw) {
    $seen[$t.Pid] = $true
    $item = $itemsByPid[$t.Pid]
    if (-not $item) {
      $item = New-Object TaskMon.Card
      $item['Pid'] = $t.Pid; $item['TitleVis'] = 'Visible'; $item['EditVis'] = 'Collapsed'
      $itemsByPid[$t.Pid] = $item
      $items.Add($item)
    }
    $item.Begin()
    $s = $t.Session
    if (-not $startDirs.ContainsKey($t.Pid)) { $startDirs[$t.Pid] = [TaskMon.Native]::StartDir($t.Pid) }
    $item['SessionId'] = $(if ($s) { [string]$s.session } else { '' })
    $item['StartDir'] = $(if ($startDirs[$t.Pid]) { [string]$startDirs[$t.Pid] } elseif ($s -and $s.root) { [string]$s.root } elseif ($s) { [string]$s.cwd } else { '' })
    $item['Cwd'] = $(if ($s -and $s.cwd) { [string]$s.cwd } else { $item['StartDir'] })
    $item['MemMB'] = $t.Mem
    $item['Created'] = $t.Created
    $item['Agents'] = $(if ($s -and [int]$s.agents -gt 0) { [int]$s.agents } else { 0 })

    # Estado: pausa del monitor > lo que anotó el mod > lo que dice el título de la terminal
    $activity = if ($t.Window) { $t.Window.Activity } else { '' }
    $hook = if ($s) { [string]$s.state } else { '' }
    $base = if ($paused.ContainsKey($t.Pid) -or $renderFrozen.Contains([int]$t.Pid)) { 'paused' }
      elseif ($resumeUntil.ContainsKey($t.Pid) -and $resumeUntil[$t.Pid] -gt $now) { 'resuming' }
      elseif ($hook -eq 'waiting') { 'waiting' }
      elseif ($activity -eq 'busy') { 'busy' }
      elseif ($activity -eq 'idle') { if ($hook -eq 'error') { 'error' } else { 'done' } }
      elseif ($hook -eq 'busy') { 'busy' }
      elseif ($hook -eq 'error') { 'error' }
      elseif ($hook -eq 'idle') { 'done' }
      else { 'unknown' }
    $hookMatches = $s -and (($base -eq $hook) -or ($base -eq 'done' -and $hook -eq 'idle'))
    $prev = $stateSince[$t.Pid]
    $since = if ($base -eq 'paused' -and $paused.ContainsKey($t.Pid)) { [long]$paused[$t.Pid].since } elseif ($base -eq 'paused' -and $prev -and $prev.State -eq 'paused') { $prev.Since } elseif ($base -eq 'paused') { $nowMs }
      elseif ($hookMatches) { [long]$s.since }
      elseif ($prev -and $prev.State -eq $base) { $prev.Since }
      else { $nowMs }
    $sawWork = ($prev -and $prev.SawWork) -or $base -in 'busy', 'waiting' -or $hookMatches
    $stateSince[$t.Pid] = @{ State = $base; Since = $since; SawWork = $sawWork }
    $state = if ($base -eq 'done' -and (-not $sawWork -or ($nowMs - $since) -gt $idleAfterMs)) { 'idle' } else { $base }

    $item['State'] = $state
    $item['LastUse'] = if ($state -in 'busy', 'waiting', 'resuming') { $nowMs } elseif ($s -and [long]$s.updated -gt 0) { [long]$s.updated } elseif ($sinceKnown -or $sawWork) { [long]$since } else { ([DateTimeOffset]$t.Created).ToUnixTimeMilliseconds() }
    $color = State-Color $state
    $item['StateColor'] = $color
    $item['StateBg'] = Alpha $color '22'
    $item['CardBg'] = Mix-Hex $color $theme.Panel $(switch ($state) { 'waiting' { 0.2 } 'error' { 0.2 } 'busy' { 0.13 } 'done' { 0.12 } 'paused' { 0.09 } default { 0.05 } })
    $item['StateLabel'] = $stateInfo[$state].Label
    $item['Blink'] = $(if ($state -in 'busy', 'waiting', 'resuming') { '1' } else { '0' })
    # Sin haberla visto trabajar no se sabe desde cuándo está parada
    $sinceKnown = $sawWork -or $state -eq 'paused'
    $ago = Format-Ago ($nowMs - $since)
    $item['StateDetail'] = switch ($state) {
      'waiting' { "te espera para $(if ($s.waitingFor -eq 'respuesta') { 'responder una pregunta' } else { 'dar un permiso' }) · $ago" }
      'unknown' { 'sin datos de esta sesión' }
      'resuming' { 'reanudando...' }
      { $_ -eq 'idle' -and -not $sinceKnown } { 'sin actividad desde que se abrió el monitor' }
      default { "$($stateInfo[$state].Verb) $ago" }
    }

    # Nombre: el que pusiste, si no el título de su ventana, si no la carpeta
    if ($t.Window -and $t.Window.Text) { $item['LastWindow'] = $t.Window.Text }
    $auto = if ($item['LastWindow']) { $item['LastWindow'] } elseif ($item['StartDir']) { Split-Path $item['StartDir'] -Leaf } else { "Sesión $($t.Pid)" }
    $item['AutoTitle'] = $auto
    $custom = Get-Meta $item 'name'
    $item['Title'] = $(if ($custom) { [string]$custom } else { $auto })
    $item['Pinned'] = [bool](Get-Meta $item 'pinned')
    $item['PinMark'] = ''

    if (-not $script:taskMemHistory.ContainsKey($t.Pid)) { $script:taskMemHistory[$t.Pid] = New-Object System.Collections.Generic.List[double] }
    Push $script:taskMemHistory[$t.Pid] $t.Mem $taskHistoryLen
    $hist = $script:taskMemHistory[$t.Pid]
    $item['Spark'] = [TaskMon.Geo]::Spark($hist.ToArray(), 84, 14, $taskHistoryLen, [Math]::Max(1.0, ($hist | Measure-Object -Maximum).Maximum * 1.15), 0).ToString([System.Globalization.CultureInfo]::InvariantCulture)

    $done = if ($s) { [int]$s.tasks } else { 0 }
    $cpuText = if ($state -eq 'paused') { 'CPU congelada' } else { '{0:N1}% CPU' -f $t.Cpu }
    $info = @((Format-MB $t.Mem), $cpuText)
    if ($s) { $info += "$done tareas" }
    if ($state -notin 'unknown', 'resuming' -and $sinceKnown) { $info += $ago }
    if ($item['Agents']) { $info += "$($item['Agents']) subagentes" }
    if ($s -and [double]$s.contextPct -gt 0) { $info += 'ctx {0:N0}%' -f [double]$s.contextPct } elseif ($s -and [long]$s.context -gt 0) { $info += "ctx $(Format-Tokens ([long]$s.context))" }
    $item['Info'] = $info -join '  ·  '
    $item['Resources'] = "$(Format-MB $t.Mem) · $cpuText · $($t.Procs) procesos"
    $item['LastPrompt'] = $(if ($s -and $s.prompt) { [string]$s.prompt } else { '' })
    $item['Prompt'] = switch ($state) {
      'waiting' { "⚠ Te espera en su terminal: $(if ($s.waitingFor -eq 'respuesta') { 'tiene una pregunta para ti' } else { 'pide permiso para usar una herramienta' })" }
      'error' { "✖ Se detuvo por un error$(if ($s.error) { ": $($s.error)" })" }
      default { if ($item['LastPrompt']) { "› $($item['LastPrompt'])" } elseif ($s) { '› sin datos todavía: envía un mensaje en esa sesión' } else { '› sesión abierta antes del mod: su estado sale del título de la terminal' } }
    }

    $age = if ($t.Created -gt [datetime]::MinValue) { Format-Ago (($now - $t.Created).TotalMilliseconds) } else { '?' }
    $tip = @(
      [string]$item['Title'],
      "Estado: $($stateInfo[$state].Label) · $($item['StateDetail'])",
      "Carpeta: $(if ($item['StartDir']) { $item['StartDir'] } else { 'desconocida' })"
    )
    if ($item['Cwd'] -and $item['Cwd'].TrimEnd('\') -ne ([string]$item['StartDir']).TrimEnd('\')) { $tip += "Ahora en: $($item['Cwd'])" }
    $tip += "Memoria: $(Format-MB $t.Mem) ($('{0:N1}' -f ($t.Mem / $totalMB * 100))% de la RAM) · $($t.Procs) procesos"
    $tip += "PID $($t.Pid) · abierta hace $age"
    if ($s) {
      $tip += "Tareas completadas: $done$(if ([long]$s.lastMs -gt 0) { " · última $(Format-Ago ([long]$s.lastMs))" })$(if ([long]$s.workMs -gt 0) { " · total $(Format-Ago ([long]$s.workMs))" })"
      if ($s.model) { $tip += "Modelo: $($s.model)$(if ([long]$s.context -gt 0) { " · contexto $(Format-Tokens ([long]$s.context)) tokens" })$(if ([double]$s.contextPct -gt 0) { " ($('{0:N0}' -f [double]$s.contextPct)%)" })" }
      $tip += "Sesión: $($s.session)"
    }
    $item['Tip'] = $tip -join "`n"
    $item.End()
  }
  foreach ($k in @($itemsByPid.Keys)) {
    if (-not $seen.ContainsKey($k)) {
      if ($script:editing -eq $itemsByPid[$k]) { $script:editing = $null }
      [void]$items.Remove($itemsByPid[$k]); $itemsByPid.Remove($k); $sceneOf.Remove($k); $spriteImg.Remove($k); $animator.Remove([int]$k); $script:taskMemHistory.Remove($k); $stateSince.Remove($k); $startDirs.Remove($k)
    }
  }
  # Grupos (fijadas / por estado / ninguno) y orden dentro de cada uno, según Ajustes
  $tasks = @(Update-Groups)
  Pick-Scenes
  Update-Sprites
  if ($ui.StageBtn.IsChecked) { Update-Stage $false }

  # Log de eventos y sonidos
  $states = @{}; foreach ($t in $tasks) { $states[$t['Pid']] = @{ State = $t['State']; Title = $t['Title']; Mem = Format-MB ([double]$t['MemMB']) } }
  if ($null -ne $script:prevStates) {
    foreach ($t in $tasks) {
      $old = $script:prevStates[$t['Pid']]
      $c = State-Color $t['State']
      if (-not $old) { Log "+ nueva sesión: $($t['Title'])" $theme.Accent2 }
      elseif ($old.State -ne $t['State']) {
        switch ($t['State']) {
          'busy' { Log "▶ $($t['Title']): EN CURSO" $c }
          'waiting' { Log "⚠ $($t['Title']): te espera en su terminal" $c; if ($settings.soundDone) { [System.Media.SystemSounds]::Question.Play() } }
          'error' { Log "✖ $($t['Title']): se detuvo por un error" $c }
          'done' {
            if ($old.State -in 'busy', 'waiting') {
              Log "■ $($t['Title']): LISTO" $c
              if ($settings.soundDone) { [System.Media.SystemSounds]::Asterisk.Play() }
            }
          }
        }
      }
    }
    foreach ($k in $script:prevStates.Keys) { if (-not $states.ContainsKey($k)) { Log "- sesión cerrada: $($script:prevStates[$k].Title) · liberados ~$($script:prevStates[$k].Mem)" $warn } }
  } else {
    Log "$($tasks.Count) sesiones detectadas · $(@($tasks | Where-Object { $_['State'] -eq 'busy' }).Count) en curso" $theme.Accent2
  }
  $script:prevStates = $states
  if ($ramLevel -ne $script:prevRamLevel) {
    switch ($ramLevel) {
      2 { Log ('!! RAM crítica: {0:N0}%' -f $ramPct) $crit; if ($settings.soundCritical) { [System.Media.SystemSounds]::Exclamation.Play() } }
      1 { Log ('! RAM alta: {0:N0}%' -f $ramPct) $warn }
      0 { Log ('RAM normalizada: {0:N0}%' -f $ramPct) $ok }
    }
    $script:prevRamLevel = $ramLevel
  }

  $count = @{}; foreach ($t in $tasks) { $count[$t['State']] = 1 + [int]$count[$t['State']] }
  $busy = [int]$count['busy']; $waiting = [int]$count['waiting']; $pausedCount = [int]$count['paused']
  $claudeMB = [double]($raw | Measure-Object Mem -Sum).Sum
  $ui.NoTasks.Visibility = $(if ($tasks.Count) { 'Collapsed' } else { 'Visible' })
  $ui.TitleSub.Text = $(if ($settings.style -eq 'trading') { "$($ui.Ticker.Text)  ·  " } else { '' }) + "$($tasks.Count) sesiones · $busy en curso$(if ($waiting) { " · $waiting te esperan" })$(if ($pausedCount) { " · $pausedCount en pausa" })"
  $ui.TasksSummary.Text = "$($tasks.Count) sesiones · $busy en curso" + $(if ($waiting) { " · $waiting esperando" } else { '' }) + $(if ($pausedCount) { " · $pausedCount en pausa" } else { '' }) + " · $(Format-MB $claudeMB)"

  # Otros programas: cada tres vueltas basta
  if ($script:tick % 3 -eq 0 -or -not $ui.Others.ItemsSource) {
    $exclude = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($k in $inTree.Keys) { [void]$exclude.Add([int]$k) }
    [void]$exclude.Add($PID)
    Update-Others $procs $exclude $nowMs
  }
  $others = @($ui.Others.ItemsSource)

  # Consejo
  $avgTask = if ($raw.Count) { [Math]::Max(250.0, $claudeMB / @($raw).Count) } else { 450.0 }
  $room = $freeMB - $totalMB * $settings.reservePct / 100
  $extra = [int][Math]::Max(0.0, [Math]::Floor($room / $avgTask))
  $ready = @($tasks | Where-Object { $_['State'] -in 'done', 'idle', 'unknown' } | Sort-Object { -[double]$_['MemMB'] })
  $readyList = ($ready | Select-Object -First 3 | ForEach-Object { "$($_['Title']) ($(Format-MB ([double]$_['MemMB'])))" }) -join ', '
  $cpuAvg = ($script:cpuHistory | Select-Object -Last 10 | Measure-Object -Average).Average
  $topOther = if ($others.Count) { "$($others[0].Name) ($($others[0].Mem))" } else { '' }

  if ($ramLevel -eq 2) {
    $color = $crit; $tag = 'ALERTA'; $title = 'Memoria crítica: riesgo de bloqueo'
    $body = if ($ready.Count) { "Pausa (clic derecho) sesiones en LISTO o INACTIVA para liberar su RAM: $readyList. Fuera de Claude, lo que más ocupa es $topOther." } elseif ($pausedCount) { "Las sesiones que no trabajan ya están en pausa. Cierra programas que no uses: lo que más ocupa es $topOther." } else { "Todas las sesiones están trabajando. Espera a que alguna termine o cierra programas: lo que más ocupa es $topOther." }
  } elseif ($ramLevel -eq 1) {
    $color = $warn; $tag = 'AVISO'; $title = 'Memoria alta: mejor no abrir más tareas'
    $body = if ($ready.Count) { "Si necesitas otra, pausa antes alguna en LISTO o INACTIVA: $readyList." } else { 'Deja que terminen las tareas actuales antes de empezar otra.' }
  } elseif ($cpuAvg -ge 90) {
    $color = $crit; $tag = 'CPU'; $title = 'CPU saturada: más tareas no irán más rápido'
    $body = "Hay RAM para ~$extra tareas más, pero la CPU está al límite."
  } elseif ($cpuAvg -ge 70) {
    $color = $warn; $tag = 'CPU'; $title = "CPU ocupada: margen para ~$extra tareas más"
    $body = "La CPU va al $('{0:N0}' -f $cpuAvg)% de media; las tareas nuevas irán algo más lentas."
  } elseif ($extra -ge 2 -and $ramPct -lt 60) {
    $color = $ok; $tag = 'OPORTUNIDAD'; $title = "Puedes lanzar ~$extra tareas más"
    $body = "Media $(Format-MB $avgTask) por sesión · te sobran $(Format-MB $room) sobre la reserva del $($settings.reservePct)%."
  } else {
    $color = $ok; $tag = 'EQUILIBRADO'; $title = "Margen para ~$extra tareas más"
    $body = "Media $(Format-MB $avgTask) por sesión · margen $(Format-MB ([Math]::Max(0.0, $room))) sobre la reserva del $($settings.reservePct)%."
  }
  $ui.AdviceCard.BorderBrush = Brush-Cached $color
  $ui.AdviceTag.Text = $tag; $ui.AdviceTag.Foreground = Brush-Cached $color
  $ui.AdviceTitle.Foreground = Brush-Cached $color
  Type-Text $ui.AdviceTitle $title
  $ui.AdviceBody.Text = $body
  if ($settings.style -eq 'nefralis') {
    $ui.AdviceMedal.BorderBrush = Brush-Cached $color
    $ui.AdviceIcon.Source = Asset-Image "icon-$(switch ($tag) { 'ALERTA' { 'escudo' } 'AVISO' { 'peso' } 'CPU' { 'entrenamiento' } 'OPORTUNIDAD' { 'nivel' } default { 'descanso' } }).png"
  }

  # Huecos: sesiones abiertas + tareas que aún caben (solo se redibujan si algo cambió)
  $sig = (($tasks | ForEach-Object { "$($_['StateColor'])$($_['Title'])" }) -join '|') + "#$extra#$ramLevel#$($style.Radius)"
  if ($sig -ne $script:slotsSig) {
    $script:slotsSig = $sig
    $ui.Slots.Children.Clear()
    $radius = [System.Windows.CornerRadius]::new([Math]::Min(5, $style.Radius))
    foreach ($t in $tasks) {
      $b = New-Object System.Windows.Controls.Border
      $b.Width = 10; $b.Height = 10; $b.Margin = '0,0,3,0'; $b.CornerRadius = $radius
      $b.Background = Brush-Cached $t['StateColor']; $b.ToolTip = "$($t['Title']) · $($t['StateLabel'])"
      [void]$ui.Slots.Children.Add($b)
    }
    for ($i = 0; $i -lt [Math]::Min($extra, 16); $i++) {
      $b = New-Object System.Windows.Controls.Border
      $b.Width = 10; $b.Height = 10; $b.Margin = '0,0,3,0'; $b.CornerRadius = $radius
      $b.BorderBrush = $theme.Deep; $b.BorderThickness = 1; $b.ToolTip = 'hueco libre para otra tarea'
      [void]$ui.Slots.Children.Add($b)
    }
  }
  $ui.SlotsText.Text = "$($tasks.Count) en uso · ~$extra libres · $(Format-MB $claudeMB) en Claude · $(Format-MB $freeMB) libres"

  $ui.NavTasksCount.Text = "$($busy + $waiting + [int]$count['resuming'])"
  try { Refresh-Renders $byId $children $nowMs } catch { if (-not $script:renderFailed) { $script:renderFailed = $true; Log "renders: $($_.Exception.Message) (línea $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))" $crit } }

  Update-Usage

  if ($ramLevel -eq 2) { $ui.StatusPill.Background = Brush-Cached $crit } elseif ($ramLevel -eq 1) { $ui.StatusPill.Background = Brush-Cached $warn } else { $ui.StatusPill.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Accent') }
  $ui.StatusLeft.Text = $(if ($ramLevel -eq 2) { '!! RAM CRÍTICA' } elseif ($busy) { "● $busy EN CURSO" } else { '● TODO LISTO' }) + $(if ($waiting) { " · $waiting ESPERANDO" } else { '' }) + $(if ($pausedCount) { " · $pausedCount EN PAUSA" } else { '' })
  $ui.StatusRight.Text = $now.ToString('HH:mm')
  $ui.StatusRight.ToolTip = "abierto hace $(Format-Ago (($now - $startedAt).TotalMilliseconds)) · se actualiza cada $($settings.refreshSec) s · $($now.ToString('HH:mm:ss'))"
}

# --- Renders de vídeo (pestaña Render) ----------------------------------------------
# Fuentes: los .json de ~/.claude/render-progress (render-con-progreso.mjs, blender-progreso.mjs), los procesos que
# renderizan aunque no publiquen nada (Blender en segundo plano, ffmpeg, HandBrake, Media Encoder, Remotion por CLI),
# los lanzadores de Blender de FORJA que esperan su turno y la cola de vídeos de FORJA (lanzar_lote.py).
$renderDir = Join-Path $env:USERPROFILE '.claude\render-progress'
$rendersFile = Join-Path $dataDir 'renders.json'
# hidden: id -> cuándo se quitó · channel: carpeta del proyecto -> canal · paused: id -> @{ since; pids } · pausedMs: id -> ms en pausa
$renderStore = @{ hidden = @{}; channel = @{}; paused = @{}; pausedMs = @{}; launched = @{}; held = @{}; frozenWait = @{}; crashed = @{}; retries = @{}; queue = @() }
$rsSaved = Read-Json $rendersFile
if ($rsSaved) { foreach ($k in 'hidden', 'channel', 'paused', 'pausedMs', 'launched', 'held', 'frozenWait', 'crashed', 'retries') { if ($rsSaved.$k) { $renderStore[$k] = To-Hashtable $rsSaved.$k } } }
if ($rsSaved -and $rsSaved.queue) { $renderStore.queue = @($rsSaved.queue) }
foreach ($k in @($renderStore.held.Keys)) { $renderStore.held[$k] = To-Hashtable $renderStore.held[$k] }
foreach ($k in @($renderStore.retries.Keys)) { if ($renderStore.retries[$k] -isnot [int] -and $renderStore.retries[$k] -isnot [long]) { $renderStore.retries.Remove($k) } }
foreach ($k in @($renderStore.paused.Keys)) { $renderStore.paused[$k] = To-Hashtable $renderStore.paused[$k] }
$rsSaved = $null
function Save-Renders { try { $renderStore | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rendersFile -Encoding UTF8 } catch {} }

$channels = [ordered]@{
  nefralis = @{ Name = 'Nefralis'; File = 'cover-nefralis.png'; Match = 'nefralis' }
  solrak   = @{ Name = 'Solrak'; File = 'cover-solrak.png'; Match = 'solrak' }
  mrowl    = @{ Name = 'Mr Owl'; File = 'cover-mrowl.png'; Match = 'mrowl|mr[ _-]?owl|el-ultimo-sueno|capgras' }
}
$renderInfo = @{
  bundling  = @{ Label = 'PREPARANDO';      Color = '#A3A3A3' }
  rendering = @{ Label = 'RENDERIZANDO';    Color = '#3B82F6' }
  encoding  = @{ Label = 'CODIFICANDO';     Color = '#06B6D4' }
  muxing    = @{ Label = 'MEZCLANDO';       Color = '#14B8A6' }
  producing = @{ Label = 'EN CURSO';        Color = '#6366F1' }
  resuming  = @{ Label = 'REANUDANDO';      Color = '#A855F7' }
  queued    = @{ Label = 'EN ESPERA';       Color = '#EAB308' }
  waiting   = @{ Label = 'ESPERANDO TURNO'; Color = '#F97316' }
  paused    = @{ Label = 'EN PAUSA';        Color = '#EC4899' }
  stopped   = @{ Label = 'DETENIDO';        Color = '#78716C' }
  done      = @{ Label = 'TERMINADO';       Color = '#22C55E' }
  finished  = @{ Label = 'FINALIZADO';      Color = '#84CC16' }
  error     = @{ Label = 'ERROR';           Color = '#EF4444' }
  stale     = @{ Label = 'INTERRUMPIDO';    Color = '#B45309' }
}
$activeStates = 'bundling', 'rendering', 'encoding', 'muxing', 'producing', 'resuming'
$renderActiveItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$renderWaitItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$renderDoneItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.RenderActive.ItemsSource = $renderActiveItems
$ui.RenderWait.ItemsSource = $renderWaitItems
$ui.RenderDone.ItemsSource = $renderDoneItems
$renderPausedItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.RenderPaused.ItemsSource = $renderPausedItems
$renderCards = @{}       # id -> tarjeta
$renderHist = @{}        # id -> muestras @(ms, renderizados, codificados) del último minuto
$renderResume = @{}      # id -> fin del estado "reanudando"
$renderPrev = $null      # id -> estado en la vuelta anterior (para el registro)
$procDone = @{}          # id -> @{ Card; Until } procesos de render que ya acabaron
$renderById = @{}
$renderChildren = @{}
$renderFailed = $false
$cmdCache = @{}          # pid -> @{ Created; Cmd; Dir }
$jobCpu = @{}            # id -> @(cpu acumulada, ms)
$forjaCanal = @{}
$forjaRoot = Join-Path $env:USERPROFILE 'OneDrive\Desktop\FORJA'
$glyphs = @{ video = [string][char]0xE714; blender = [string][char]0xE809; wait = [string][char]0xE916; queue = [string][char]0xE8FD; ffmpeg = [string][char]0xE8B2 }

$cut = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 3 * 86400000
foreach ($k in @($renderStore.hidden.Keys)) { if ([long]$renderStore.hidden[$k] -lt $cut) { $renderStore.hidden.Remove($k) } }
foreach ($k in @($renderStore.pausedMs.Keys)) { if (-not $renderStore.paused.ContainsKey($k) -and -not [IO.File]::Exists((Join-Path $renderDir "$k.json"))) { $renderStore.pausedMs.Remove($k) } }

function Format-Dur([double]$ms) {
  $s = [long][Math]::Max(0, [Math]::Round($ms / 1000))
  if ($s -lt 60) { "$s s" } elseif ($s -lt 3600) { '{0} min {1:00} s' -f [Math]::Floor($s / 60), ($s % 60) } else { '{0} h {1:00} min' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60) }
}
function Format-Size([double]$bytes) { if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) } else { '{0:N0} MB' -f ($bytes / 1MB) } }

function Render-Root([string]$output) {
  if (-not $output) { return '' }
  $d = if ($output -match '\.(mp4|mov|webm|mkv|gif|png|jpg)$') { Split-Path $output -Parent } else { $output }
  for ($i = 0; $i -lt 3 -and $d; $i++) {
    if ((Split-Path $d -Leaf) -match '^(out|output|exports?|entrega|render|renders|public|shots|\d\d_\w+)$') { $d = Split-Path $d -Parent } else { break }
  }
  $d
}
function Render-Channel([string]$root, [string]$text) {
  if ($root -and $renderStore.channel.ContainsKey($root)) { return [string]$renderStore.channel[$root] }
  foreach ($k in $channels.Keys) { if ($text -match $channels[$k].Match) { return $k } }
  ''
}

# Línea de comandos y carpeta de arranque de un proceso, leídas una vez por proceso
function Proc-Info($p) {
  $c = $cmdCache[$p.Pid]
  if ($c -and $c.Created -eq $p.Created) { return $c }
  $c = @{ Created = $p.Created; Cmd = [string][TaskMon.Native]::CommandLine($p.Pid); Dir = [string][TaskMon.Native]::StartDir($p.Pid) }
  $cmdCache[$p.Pid] = $c
  $c
}
# Un proceso y todo lo que cuelga de él (sin consolas)
function Tree-Pids([int]$root, [bool]$withClaude = $false) {
  $list = New-Object System.Collections.Generic.List[int]
  $stack = New-Object System.Collections.Generic.Stack[int]; $stack.Push($root)
  $seen = @{}
  while ($stack.Count) {
    $id = $stack.Pop()
    if ($seen.ContainsKey($id) -or $id -eq $PID) { continue }
    $seen[$id] = $true
    $p = $renderById[$id]; if (-not $p) { continue }
    if ($p.Name -notin 'conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe', 'explorer.exe' -and ($withClaude -or $p.Name -ne 'claude.exe')) { $list.Add($id) }
    if ($renderChildren.ContainsKey($id)) { foreach ($c in $renderChildren[$id]) { $stack.Push($c) } }
  }
  $list.ToArray()
}
function Ancestors([int]$id) {
  $out = New-Object System.Collections.Generic.List[int]
  $p = $renderById[$id]
  for ($i = 0; $i -lt 12 -and $p -and $p.Ppid -and $renderById.ContainsKey($p.Ppid); $i++) {
    $par = $renderById[$p.Ppid]
    if ($par.Created -gt $p.Created) { break }   # pid reutilizado: no es su padre de verdad
    $out.Add($par.Pid); $p = $par
  }
  $out
}
# CPU del árbol desde la vuelta anterior, en % de toda la máquina
function Tree-Cpu([string]$id, [int[]]$pids, [long]$nowMs) {
  $sum = 0.0
  foreach ($x in $pids) { $q = $renderById[$x]; if ($q) { $sum += $q.CpuTime / 1e7 } }
  $prev = $jobCpu[$id]
  $jobCpu[$id] = @($sum, $nowMs)
  if (-not $prev -or $nowMs -le $prev[1]) { return $null }
  [Math]::Max(0.0, [Math]::Min(100.0, ($sum - $prev[0]) / (($nowMs - $prev[1]) / 1000.0) / $cores * 100))
}
# Rutas largas a su último nombre, para enseñar un comando en una línea
function Short-Args([string]$s) {
  $s = $s -replace '"', ''
  $s = $s -replace '(?:[A-Za-z]:)?[\\/]?(?:[^\s\\/]+[\\/])+([^\s\\/]+)', '$1'
  $s = ($s -replace '\s+', ' ').Trim()
  if ($s.Length -gt 70) { $s.Substring(0, 70) + '…' } else { $s }
}

# --- Blender: qué toma está pintando y cuántos fotogramas lleva (lee la carpeta de salida y el script)
$planCache = @{}
function Blender-Progress([string]$outDir, [string]$scriptPath, [string]$cmd) {
  if (-not $outDir -or -not [IO.Directory]::Exists($outDir)) { return $null }
  $totals = @{}
  if ($scriptPath -and [IO.File]::Exists($scriptPath)) {
    $wt = [IO.File]::GetLastWriteTimeUtc($scriptPath)
    $c = $planCache[$scriptPath]
    if (-not $c -or $c.T -ne $wt) {
      $map = @{}
      foreach ($mm in [regex]::Matches([IO.File]::ReadAllText($scriptPath), '@plano\(\s*"([^"]+)"\s*,\s*frames\s*=\s*(\d+)')) { $map[$mm.Groups[1].Value] = [int]$mm.Groups[2].Value }
      $c = @{ T = $wt; Map = $map }; $planCache[$scriptPath] = $c
    }
    $totals = $c.Map
  }
  $only = if ($cmd -match '--only=([^\s"]+)') { @($matches[1] -split ',') } else { @() }
  $dirs = @([IO.Directory]::GetDirectories($outDir) | ForEach-Object { New-Object IO.DirectoryInfo $_ })
  if ($only.Count) { $dirs = @($dirs | Where-Object { $_.Name -in $only }) }
  if (-not $dirs.Count) { $dirs = @(New-Object IO.DirectoryInfo $outDir) }
  $counts = @{}; $newest = $null; $newestTime = [datetime]::MinValue; $files = $null
  foreach ($d in $dirs) {
    $f = @($d.GetFiles() | Where-Object { $_.Extension -in '.png', '.jpg', '.jpeg', '.exr', '.tif' } | Sort-Object LastWriteTime)
    $counts[$d.Name] = $f.Count
    if ($f.Count -and $f[$f.Count - 1].LastWriteTime -gt $newestTime) { $newestTime = $f[$f.Count - 1].LastWriteTime; $newest = $d; $files = $f }
  }
  if (-not $newest) { return $null }
  $done = $files.Count
  $total = [int]$totals[$newest.Name]
  # Segundos por fotograma: los últimos fotogramas de la toma en curso
  $spf = 0.0
  $tail = @($files | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } | Select-Object -Last 8)
  if ($tail.Count -ge 3) { $spf = ($tail[$tail.Count - 1].LastWriteTime - $tail[0].LastWriteTime).TotalSeconds / ($tail.Count - 1) }
  if ($spf -gt 900) { $spf = 0.0 }
  $left = [Math]::Max(0, $total - $done)
  $shotIdx = 0; $shotN = $only.Count
  if ($shotN) {
    $shotIdx = [Array]::IndexOf($only, $newest.Name) + 1
    foreach ($s in $only) { if ($s -ne $newest.Name -and $totals.ContainsKey($s) -and [int]$counts[$s] -lt $totals[$s]) { $left += $totals[$s] - [int]$counts[$s] } }
  }
  $ago = ((Get-Date) - $newestTime).TotalMilliseconds
  $etaMs = if ($spf -gt 0 -and $total) { $left * $spf * 1000 } else { $null }
  $text = "$($newest.Name) $done$(if ($total) { "/$total" })$(if ($shotN -gt 1) { " (toma $shotIdx de $shotN)" }) · último fotograma hace $(Format-Dur $ago)$(if ($spf -gt 0) { ' · {0:N0} s/fotograma' -f $spf })$(if ($null -ne $etaMs) { " · tomas listas en ~$(Format-Dur $etaMs)" })"
  @{ Shot = $newest.Name; Done = $done; Total = $total; EtaMs = $etaMs; Text = $text; Stalled = $ago -gt [Math]::Max(180000, $spf * 4000) }
}

# --- FORJA: a qué vídeo pertenece algo y cómo va ese vídeo
function Forja-Video([string]$text) {
  if ($text -match 'runs[\\/](\d{8}-\d{6})[\\/]video(\d+)') { return @{ Run = $matches[1]; N = [int]$matches[2]; Mid = "r$($matches[1] -replace '-', '_')_v$($matches[2])" } }
  if ($text -match 'r(\d{8})_(\d{6})_v(\d+)') { return @{ Run = "$($matches[1])-$($matches[2])"; N = [int]$matches[3]; Mid = "r$($matches[1])_$($matches[2])_v$($matches[3])" } }
  $null
}
function Forja-State($fv) {
  $vdir = Join-Path $forjaRoot "runs\$($fv.Run)\video$($fv.N)"
  if (-not $forjaCanal.ContainsKey($fv.Run)) {
    $canal = ''
    try { $canal = [string]([IO.File]::ReadAllText((Join-Path $forjaRoot "runs\$($fv.Run)\estado.json")) | ConvertFrom-Json).canal } catch {}
    $forjaCanal[$fv.Run] = $canal
  }
  $prog = $null
  $pf = Join-Path $vdir '08_prompt\progreso.json'
  if ([IO.File]::Exists($pf)) { $prog = Read-Json-Cached $pf }
  @{
    Dir = $vdir; Canal = [string]$forjaCanal[$fv.Run]; Prog = $prog
    Entrega = Join-Path $forjaRoot "runs\$($fv.Run)\ENTREGA\$($fv.Mid).mp4"
    Delivered = [IO.File]::Exists((Join-Path $vdir 'ENTREGADO.md')) -or ($prog -and $prog.fase -eq 'entregado')
  }
}
$phaseOrder = @('revisando', 'audio', '3d', 'montaje', 'render', 'entregado')

# Valores comunes de una tarjeta
function Card-Look($card, [string]$state, [string]$chan, [string]$glyph) {
  $color = $renderInfo[$state].Color
  $card['State'] = $state
  $card['StateColor'] = $color
  $card['Bar2Color'] = Mix-Hex $color '#FFFFFF' 0.62
  $card['StateLabel'] = $renderInfo[$state].Label
  $card['CardBg'] = Mix-Hex $color $theme.Panel $(switch ($state) { 'paused' { 0.1 } 'error' { 0.14 } { $_ -in 'stale', 'queued', 'waiting' } { 0.06 } { $_ -in 'done', 'finished' } { 0.07 } default { 0.12 } })
  $card['Blink'] = $(if ($state -in $activeStates) { '1' } else { '0' })
  $card['Channel'] = $chan
  $cover = if ($chan -and $channels.Contains($chan)) { Asset-Image $channels[$chan].File } else { $null }
  $card['Cover'] = $(if ($cover) { [System.Windows.Media.ImageSource]$cover } else { $null })
  $card['Glyph'] = $glyph
  $card['GlyphVis'] = $(if ($cover) { 'Collapsed' } else { 'Visible' })
  $overlay = switch ($state) { 'paused' { [string][char]0xE769 } 'error' { [string][char]0xE711 } 'stale' { [string][char]0xE7BA } 'waiting' { [string][char]0xE916 } 'queued' { [string][char]0xE8FD } 'halted' { [string][char]0xE769 } 'stopped' { [string][char]0xE71A } default { '' } }
  $card['Overlay'] = $overlay
  $card['OverlayVis'] = $(if ($overlay) { 'Visible' } else { 'Collapsed' })
  $card['EtaColor'] = [System.Windows.Media.Brush](Brush-Cached $(switch ($state) { 'error' { $renderInfo.error.Color } 'stale' { $renderInfo.stale.Color } { $_ -in 'paused', 'halted' } { $renderInfo.paused.Color } 'stopped' { $renderInfo.stopped.Color } { $_ -in 'done', 'finished' } { $renderInfo.done.Color } default { $theme.Soft } }))
}
function Get-Card([string]$id, [string]$kind) {
  $card = $renderCards[$id]
  if (-not $card) { $card = New-Object TaskMon.Card; $card['Id'] = $id; $renderCards[$id] = $card }
  $card['Kind'] = $kind
  $card
}

function Mark-RenderJson($item, [bool]$isPaused) {
  try {
    $path = [string]$item['Path']
    $r = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $r | Add-Member -NotePropertyName paused -NotePropertyValue $isPaused -Force
    $r.updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [IO.File]::WriteAllText($path, ($r | ConvertTo-Json -Compress -Depth 4))
  } catch {}
}
# Lo que se congela al pausar: el árbol del render; si es de Blender con progreso publicado, también los blender.exe
function Render-Pids($item) {
  $all = New-Object System.Collections.Generic.List[int]
  if ([int]$item['Pid']) { foreach ($x in (Tree-Pids ([int]$item['Pid']))) { $all.Add($x) } }
  if ($item['Kind'] -eq 'render' -and $item['Blender']) { foreach ($p in $renderById.Values) { if ($p.Name -eq 'blender.exe') { foreach ($x in (Tree-Pids $p.Pid)) { $all.Add($x) } } } }
  @($all | Select-Object -Unique)
}
function Pause-Render($item) {
  $id = [string]$item['Id']
  $pids = @(Render-Pids $item)
  $ok = 0
  foreach ($p in $pids) { if ([TaskMon.Native]::Suspend($p)) { $ok++ } }
  if (-not $ok) { Log "no se pudo pausar $($item['Title'])" $crit; return }
  $renderStore.paused[$id] = @{ since = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); pids = $pids }
  Save-Renders
  $renderHist.Remove($id)
  if ($item['Kind'] -eq 'render') { Mark-RenderJson $item $true }
  Log "❚❚ render en pausa: $($item['Title']) · $ok procesos congelados" $renderInfo.paused.Color
  Refresh
}
function Resume-Render($item) {
  $id = [string]$item['Id']
  if (-not $renderStore.paused.ContainsKey($id) -and $item['Kind'] -eq 'render') { Relaunch-Render $item; return }
  $entry = $renderStore.paused[$id]
  $pids = @(@($entry.pids) + @(Render-Pids $item) | Where-Object { $_ } | Select-Object -Unique)
  Thaw-Pids $pids
  if ($entry) { $renderStore.pausedMs[$id] = [long]$renderStore.pausedMs[$id] + ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$entry.since) }
  $renderStore.paused.Remove($id); Save-Renders
  $renderHist.Remove($id)
  $renderResume[$id] = (Get-Date).AddSeconds(3)
  if ($item['Kind'] -eq 'render') { Mark-RenderJson $item $false }
  Log "▶ reanudando: $($item['Title'])" $renderInfo.resuming.Color
  Refresh
}
function Resume-AllRenders {
  foreach ($k in @($renderStore.paused.Keys)) { foreach ($p in @($renderStore.paused[$k].pids)) { [void][TaskMon.Native]::Resume([int]$p) } }
  $renderStore.paused.Clear(); Save-Renders
}
function Cancel-Render($item) {
  $kind = [string]$item['Kind']
  $what = if ($kind -eq 'wait') { "Se quitará de la cola de Blender el trabajo de $($item['Title']) ($($item['Job'])). Quien lo lanzó verá que falló." } else { "Se detendrá $($item['Title']) y todo lo que ha lanzado. El archivo a medias no sirve." }
  if (-not (Confirm-Dialog $(if ($kind -eq 'wait') { 'Quitar de la cola' } else { 'Cancelar el render' }) $what $(if ($kind -eq 'wait') { 'Quitar' } else { 'Cancelar render' }))) { return }
  $id = [string]$item['Id']
  $pids = @(Render-Pids $item)
  Thaw-Pids $pids
  foreach ($p in $pids) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
  $renderStore.paused.Remove($id); Save-Renders
  if ($kind -eq 'render') {
    try {
      $path = [string]$item['Path']
      $r = [IO.File]::ReadAllText($path) | ConvertFrom-Json
      $r.stage = 'error'; $r.error = 'cancelado desde el monitor'; $r.etaMs = $null
      $r | Add-Member -NotePropertyName paused -NotePropertyValue $false -Force
      $r.updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      [IO.File]::WriteAllText($path, ($r | ConvertTo-Json -Compress -Depth 4))
    } catch {}
  }
  $procDone.Remove($id); $script:skipDone = $id
  Log "✖ $(if ($kind -eq 'wait') { 'quitado de la cola' } else { 'render cancelado' }): $($item['Title']) · $($pids.Count) procesos detenidos" $crit
  Refresh
}
function Open-RenderFolder($item) {
  $out = [string]$item['Output']
  if ($out -and [IO.File]::Exists($out)) { Start-Process explorer.exe -ArgumentList "/select,`"$out`""; return }
  $d = if ($out -match '\.\w{2,4}$') { Split-Path $out -Parent } else { $out }
  while ($d -and -not [IO.Directory]::Exists($d)) { $d = Split-Path $d -Parent }
  if (-not $d -and $item['Root'] -and [IO.Directory]::Exists([string]$item['Root'])) { $d = [string]$item['Root'] }
  if ($d) { Start-Process explorer.exe -ArgumentList "`"$d`"" } else { Log "no existe la carpeta de $($item['Title'])" $warn }
}
function Set-RenderChannel($item, [string]$ch) {
  $root = [string]$item['Root']
  if (-not $root) { return }
  if ($ch -eq 'auto') { $renderStore.channel.Remove($root) } else { $renderStore.channel[$root] = $ch }
  Save-Renders
  Log "🖼 portada de $($item['Title']): $(if ($ch -eq 'auto') { 'automática' } else { $channels[$ch].Name })" $theme.Accent2
  Refresh
}

# --- Una vuelta: lee todo y pone las tarjetas en sus tres listas
function Refresh-Renders($byId, $children, [long]$nowMs) {
  $script:renderById = $byId; $script:renderChildren = $children
  $now = Get-Date
  $active = New-Object System.Collections.Generic.List[object]
  $waiting = New-Object System.Collections.Generic.List[object]
  $finished = New-Object System.Collections.Generic.List[object]
  $states = @{}
  $covered = @{}         # pids que ya pertenecen a un render con progreso publicado
  $jsonBlender = $false
  $bridge = @{}         # mid -> lo que publica el puente de la cola de FORJA (forja-*.json)

  # 1. Renders que publican su progreso
  $files = if ([IO.Directory]::Exists($renderDir)) { [IO.Directory]::GetFiles($renderDir, '*.json') } else { @() }
  foreach ($path in $files) {
    $id = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($renderStore.hidden.ContainsKey($id)) { continue }
    $isPaused = $renderStore.paused.ContainsKey($id)
    if (-not $isPaused -and ($now.ToUniversalTime() - [IO.File]::GetLastWriteTimeUtc($path)).TotalHours -gt 24) { continue }
    $r = Read-Json-Cached $path
    if (-not $r) { continue }
    if ($id -like 'forja-*') {
      $bfv = Forja-Video ([string]$r.output + ' ' + $id)
      if (-not $bfv -and $id -match '^forja-(\d{8}-\d{6})-v(\d+)$') { $bfv = @{ Run = $matches[1]; N = [int]$matches[2]; Mid = "r$($matches[1] -replace '-', '_')_v$($matches[2])" } }
      if ($bfv -and ($nowMs - [long]$r.updatedAt) -lt 6 * 3600000) { $bridge[$bfv.Mid] = @{ Fv = $bfv; R = $r } }
      continue
    }
    $stage = [string]$r.stage
    $rpid = [int]$r.pid
    $alive = $rpid -and $byId.ContainsKey($rpid)
    $age = $nowMs - [long]$r.updatedAt
    if ($isPaused -and -not $alive) { Thaw-Pids $renderStore.paused[$id].pids; $renderStore.paused.Remove($id); Save-Renders; $isPaused = $false }
    $state = if ($isPaused) { 'paused' }
      elseif ($renderResume.ContainsKey($id) -and $renderResume[$id] -gt $now) { 'resuming' }
      elseif ($stage -in 'done', 'error') { $stage }
      elseif ($stage -eq 'paused') { 'paused' }
      elseif (($rpid -and -not $alive -and $age -gt 10000) -or (-not $rpid -and $age -gt 45000)) { 'stale' }
      elseif ($renderInfo.ContainsKey($stage)) { $stage }
      else { 'rendering' }
    $states[$id] = $state

    $card = Get-Card $id 'render'
    $card.Begin()
    $output = [string]$r.output
    $root = Render-Root $output
    $isBlender = "$($r.title) $output" -match 'blender'
    if ($isBlender -and $state -in $activeStates + 'paused') { $jsonBlender = $true }
    if ($alive -and $state -notin 'done', 'error', 'stale') { foreach ($x in (Tree-Pids $rpid)) { $covered[$x] = $true } }
    $fv = Forja-Video "$output $($r.title)"
    $fs = if ($fv) { Forja-State $fv } else { $null }
    $chan = if ($root -and $renderStore.channel.ContainsKey($root)) { [string]$renderStore.channel[$root] } elseif ($fs -and $fs.Canal) { $fs.Canal } else { Render-Channel $root "$output $($r.title) $root" }
    $title = if ($output -match '[\\/]([^\\/]+\.(mp4|mov|webm|mkv))$') { $matches[1] } else { [string]$r.title }
    $total = [long]$r.total; $rendered = [long]$r.rendered; $encoded = [long]$r.encoded
    $card['Path'] = $path; $card['Pid'] = $rpid; $card['Output'] = $output; $card['Root'] = $root; $card['Blender'] = $isBlender
    $card['Session'] = [string]$r.session; $card['Title'] = $title
    $card['Mid'] = $(if ($fv) { $fv.Mid } else { '' })
    $card['CanResume'] = [bool]($r.resume -and -not $alive)
    Card-Look $card $state $chan $glyphs.video
    $rf = if ($total -gt 0) { [Math]::Min(1.0, $rendered / $total) } else { 0.0 }
    $ef = if ($total -gt 0) { [Math]::Min(1.0, $encoded / $total) } else { 0.0 }
    if ($state -eq 'done') { $rf = 1.0; $ef = 1.0 }
    $card['Bar1Label'] = 'Fotogramas'; $card['Bar2Label'] = 'Codificación'
    $card['RFrac'] = $rf; $card['EFrac'] = $ef
    $card['RText'] = $(if ($total -gt 0) { '{0:N0}/{1:N0}' -f $rendered, $total } else { '—' })
    $card['EText'] = $(if ($total -gt 0) { '{0:N0} %' -f ($ef * 100) } else { '—' })
    $pct = if ($state -eq 'done') { 100 } elseif ($stage -eq 'rendering') { $rf * 100 } else { ($rf + $ef) / 2 * 100 }

    if ($state -in 'rendering', 'encoding', 'muxing') {
      if (-not $renderHist.ContainsKey($id)) { $renderHist[$id] = New-Object System.Collections.Generic.List[object] }
      $h = $renderHist[$id]
      if (-not $h.Count -or $h[$h.Count - 1][1] -ne $rendered -or $h[$h.Count - 1][2] -ne $encoded -or $nowMs - $h[$h.Count - 1][0] -gt 5000) { $h.Add(@($nowMs, $rendered, $encoded)) }
      while ($h.Count -gt 2 -and $nowMs - $h[0][0] -gt 60000) { $h.RemoveAt(0) }
    }
    $rRate = 0.0; $eRate = 0.0
    $h = $renderHist[$id]
    if ($h -and $h.Count -ge 2) {
      $dt = ($h[$h.Count - 1][0] - $h[0][0]) / 1000.0
      if ($dt -ge 6) { $rRate = ($h[$h.Count - 1][1] - $h[0][1]) / $dt; $eRate = ($h[$h.Count - 1][2] - $h[0][2]) / $dt }
    }
    $pausedMs = [long]$renderStore.pausedMs[$id]
    $pauseNow = if ($isPaused) { $nowMs - [long]$renderStore.paused[$id].since } else { 0 }
    $endMs = if ($state -in 'done', 'error', 'stale') { [long]$r.updatedAt } else { $nowMs }
    $runMs = [Math]::Max(0, $endMs - [long]$r.startedAt - $pausedMs - $pauseNow)
    $etaMs = $null
    if ($state -eq 'rendering' -or ($state -eq 'resuming' -and $stage -eq 'rendering')) {
      if ($rRate -gt 0.05) { $etaMs = ($total - $rendered) / $rRate * 1000 }
      elseif ($null -ne $r.etaMs -and -not $pausedMs) { $etaMs = [Math]::Max(0, [double]$r.etaMs - $age) }
    } elseif ($state -eq 'encoding' -and $eRate -gt 0.05) { $etaMs = ($total - $encoded) / $eRate * 1000 }
    $chanName = if ($chan -and $channels.Contains($chan)) { $channels[$chan].Name } else { 'Sin canal' }
    $fps = if ($state -eq 'encoding') { $eRate } else { $rRate }
    $card['Eta'] = switch ($state) {
      'bundling' { "$chanName · preparando el proyecto… · $(Format-Dur $runMs)" }
      'muxing' { "$chanName · mezclando el audio, casi listo · $(Format-Dur $runMs)" }
      'paused' {
        if ($isPaused) { "$chanName · ❚❚ en pausa desde hace $(Format-Dur $pauseNow) · lleva $('{0:N0}' -f $pct) %" }
        elseif ($alive -and $r.retryAt) { "$chanName · ❚❚ en pausa por un error · lo reintenta solo a las $(([DateTimeOffset]::FromUnixTimeMilliseconds([long]$r.retryAt)).LocalDateTime.ToString('HH:mm:ss')) desde el último trozo" }
        elseif ($alive) { "$chanName · ❚❚ en pausa por un error · reintentando…" }
        else { "$chanName · ❚❚ en pausa por un error ($(([string]$r.error -replace '\s+', ' ').Substring(0, [Math]::Min(60, ([string]$r.error).Length)))) · clic derecho → Reanudar" }
      }
      'resuming' { "$chanName · reanudando…" }
      'done' {
        $size = ''
        if ($output -and [IO.File]::Exists($output)) { $size = " · $(Format-Size (New-Object IO.FileInfo $output).Length)" }
        "$chanName · terminado en $(Format-Dur $runMs) · hace $(Format-Dur ($nowMs - [long]$r.updatedAt))$size"
      }
      'error' { "✖ $(if ($r.error) { ([string]$r.error -replace '\s+', ' ') } else { 'el render falló' })" }
      'stale' { "$chanName · se cortó sin terminar · hace $(Format-Dur ($nowMs - [long]$r.updatedAt))" }
      default {
        $parts = @($chanName)
        if ($null -ne $etaMs) { $parts += "quedan ~$(Format-Dur $etaMs) (≈ $($now.AddMilliseconds($etaMs).ToString('HH:mm')))" } else { $parts += 'calculando lo que queda…' }
        if ($fps -gt 0) { $parts += ('{0:N1} fps' -f $fps) }
        $parts += Format-Dur $runMs
        $parts -join ' · '
      }
    }
    $tip = @($title, "Estado: $($renderInfo[$state].Label)", "Vídeo: $output")
    if ($root) { $tip += "Proyecto: $root" }
    $tip += "Portada: $chanName · $(if ($isBlender) { 'Blender' } else { 'Remotion' }) · $('{0:N0}' -f $pct) %"
    $tip += "Empezó: $(([DateTimeOffset]::FromUnixTimeMilliseconds([long]$r.startedAt)).LocalDateTime.ToString('dd/MM HH:mm')) · $(Format-Dur $runMs) de trabajo$(if ($pausedMs + $pauseNow) { " · $(Format-Dur ($pausedMs + $pauseNow)) en pausa" })"
    if ($rpid) { $tip += "PID $rpid$(if (-not $alive) { ' (ya no corre)' })" }
    $card['Tip'] = $tip -join "`n"
    $card['Sort'] = $(if ($state -in 'done', 'error', 'stale') { 0 - [long]$r.updatedAt } else { [long]$r.startedAt })
    $card.End()
    if ($state -in 'done', 'error', 'stale') { $finished.Add($card) } else { $active.Add($card) }
  }

  # 2. Procesos: renders de otros programas y lanzadores de Blender que esperan turno
  $jobs = New-Object System.Collections.Generic.List[object]
  $launchers = @{}
  $sessions = @{}
  $lote = $null
  foreach ($p in $byId.Values) {
    $n = $p.Name
    if ($n -notin 'blender.exe', 'ffmpeg.exe', 'HandBrakeCLI.exe', 'Adobe Media Encoder.exe', 'node.exe', 'python.exe', 'pythonw.exe', 'claude.exe') { continue }
    if ($covered.ContainsKey($p.Pid)) { continue }
    $info = Proc-Info $p
    $cmd = $info.Cmd
    switch ($n) {
      'blender.exe' { if ($cmd -match '(^|\s)(-b|--background)(\s|$)') { $jobs.Add(@{ P = $p; Engine = 'Blender'; Cmd = $cmd; Dir = $info.Dir }) } }
      'ffmpeg.exe' { $jobs.Add(@{ P = $p; Engine = 'ffmpeg'; Cmd = $cmd; Dir = $info.Dir }) }
      'HandBrakeCLI.exe' { $jobs.Add(@{ P = $p; Engine = 'HandBrake'; Cmd = $cmd; Dir = $info.Dir }) }
      'Adobe Media Encoder.exe' { $jobs.Add(@{ P = $p; Engine = 'Media Encoder'; Cmd = $cmd; Dir = $info.Dir }) }
      'claude.exe' { if ($cmd -match '(^|\s)(-p|--print)(\s|$)') { $vv = Forja-Video $cmd; if ($vv) { $sessions[$vv.Mid] = $p.Pid } } }
      'node.exe' { if ($cmd -match 'remotion' -and $cmd -match '\brender\b' -and $cmd -notmatch 'render-con-progreso|blender-progreso|studio|preview') { $jobs.Add(@{ P = $p; Engine = 'Remotion'; Cmd = $cmd; Dir = $info.Dir }) } }
      default {
        if ($cmd -match 'lanzar_lote\.py') { $lote = @{ P = $p; Cmd = $cmd; Dir = $info.Dir } }
        elseif ($cmd -match '(?i)[\\/\s"](blender|lanza_blender|bl|lote|cola_turno)\.py\b') { $launchers[$p.Pid] = @{ P = $p; Cmd = $cmd; Dir = $info.Dir } }
      }
    }
  }
  if ($lote -and $lote.Dir -and [IO.Directory]::Exists((Join-Path $lote.Dir 'runs'))) { $script:forjaRoot = $lote.Dir }
  # Trabajos dentro de otro trabajo (el ffmpeg de un Remotion, el Blender de un lanzador...) cuentan con el de fuera
  $jobPids = @{}; foreach ($j in $jobs) { $jobPids[$j.P.Pid] = $true }
  $seenProc = @{}
  foreach ($j in $jobs) {
    $anc = Ancestors $j.P.Pid
    if (@($anc | Where-Object { $jobPids.ContainsKey($_) -or $covered.ContainsKey($_) }).Count) { continue }
    if ($jsonBlender -and $j.Engine -eq 'Blender') { continue }
    $p = $j.P
    $id = "proc:$($p.Pid)"
    $seenProc[$id] = $true
    $ctx = $j.Cmd + ' ' + $j.Dir
    foreach ($a in $anc) { if ($launchers.ContainsKey($a)) { $ctx += ' ' + $launchers[$a].Cmd + ' ' + $launchers[$a].Dir; $launchers.Remove($a) } }
    $fv = Forja-Video $ctx
    $fs = if ($fv) { Forja-State $fv } else { $null }
    # Salida: el último argumento con extensión de vídeo, o lo que va tras -o, o la carpeta de los argumentos
    $output = ''
    $tokens = @([regex]::Matches($j.Cmd, '"[^"]+"|\S+') | ForEach-Object { $_.Value.Trim('"') })
    for ($i = $tokens.Count - 1; $i -ge 1 -and -not $output; $i--) { if ($tokens[$i] -match '\.(mp4|mov|mkv|webm|avi|m4v|mp3|wav|m4a|gif)$') { $output = $tokens[$i] } }
    if (-not $output -and $j.Engine -eq 'Blender') {
      $o = [Array]::IndexOf($tokens, '-o'); if ($o -ge 0 -and $o + 1 -lt $tokens.Count) { $output = $tokens[$o + 1] -replace '#+.*$', '' }
      if (-not $output) { for ($i = $tokens.Count - 1; $i -ge 1 -and -not $output; $i--) { if ($tokens[$i] -match '^[A-Za-z]:[\\/]' -and $tokens[$i] -notmatch '\.(py|exe|blend)$') { $output = $tokens[$i] } } }
    }
    if ($output -and -not [IO.Path]::IsPathRooted($output) -and $j.Dir) { $output = Join-Path $j.Dir $output }
    $script = ''
    $sp = [Array]::IndexOf($tokens, '-P'); if ($sp -lt 0) { $sp = [Array]::IndexOf($tokens, '--python') }
    if ($sp -ge 0 -and $sp + 1 -lt $tokens.Count) { $script = Split-Path $tokens[$sp + 1] -Leaf }
    $bp = $null
    if ($j.Engine -eq 'Blender' -and $sp -ge 0 -and $sp + 1 -lt $tokens.Count) {
      $sPath = $tokens[$sp + 1]; if (-not [IO.Path]::IsPathRooted($sPath) -and $j.Dir) { $sPath = Join-Path $j.Dir $sPath }
      try { $bp = Blender-Progress $(if ($output -and [IO.Directory]::Exists($output)) { $output } else { '' }) $sPath $j.Cmd } catch {}
    }
    $title = if ($fv) { "$($fv.Mid).mp4" } elseif ($output -match '\.(mp4|mov|mkv|webm|avi|m4v|gif)$') { Split-Path $output -Leaf } elseif ($script) { "$($j.Engine) · $script" } else { "$($j.Engine) · $(Split-Path $j.Dir -Leaf)" }
    $root = if ($fs) { $fs.Dir } elseif ($output) { Render-Root $output } else { $j.Dir }
    $chan = if ($root -and $renderStore.channel.ContainsKey($root)) { [string]$renderStore.channel[$root] } elseif ($fs -and $fs.Canal) { $fs.Canal } else { Render-Channel $root $ctx }
    $isPaused = $renderStore.paused.ContainsKey($id)
    $state = if ($isPaused) { 'paused' } elseif ($renderResume.ContainsKey($id) -and $renderResume[$id] -gt $now) { 'resuming' } else { 'rendering' }
    $states[$id] = $state
    $pids = @(Tree-Pids $p.Pid)
    $cpu = Tree-Cpu $id $pids $nowMs
    $card = Get-Card $id 'proc'
    $card.Begin()
    $card['Pid'] = $p.Pid; $card['Output'] = $(if ($output) { $output } else { $root }); $card['Root'] = $root; $card['Title'] = $title
    $card['Cmd'] = $j.Cmd; $card['Engine'] = $j.Engine; $card['Job'] = $(if ($script) { $script } else { $j.Engine })
    $card['Mid'] = $(if ($fv) { $fv.Mid } else { '' }); $card['BpText'] = $(if ($bp) { $bp.Text } else { '' })
    Card-Look $card $state $chan $(if ($j.Engine -eq 'Blender') { $glyphs.blender } elseif ($j.Engine -eq 'ffmpeg') { $glyphs.ffmpeg } else { $glyphs.video })
    $pct = if ($fs -and $fs.Prog) { [double]$fs.Prog.pct } else { -1 }
    if ($bp -and $bp.Total) { $card['Bar1Label'] = 'Toma'; $card['RFrac'] = [double][Math]::Min(1.0, $bp.Done / $bp.Total); $card['RText'] = "$($bp.Done)/$($bp.Total)" }
    else { $card['Bar1Label'] = 'Vídeo'; $card['RFrac'] = $(if ($pct -ge 0) { $pct / 100 } else { 0.0 }); $card['RText'] = $(if ($pct -ge 0) { '{0:N0} %' -f $pct } else { '?' }) }
    $card['Bar2Label'] = 'CPU'; $card['EFrac'] = $(if ($null -ne $cpu) { $cpu / 100 } else { 0.0 }); $card['EText'] = $(if ($null -ne $cpu) { '{0:N0} %' -f $cpu } else { '…' })
    $runMs = ($now - $p.Created).TotalMilliseconds - [long]$renderStore.pausedMs[$id]
    $chanName = if ($chan -and $channels.Contains($chan)) { $channels[$chan].Name } else { 'Sin canal' }
    $size = ''
    if ($output -and [IO.File]::Exists($output)) { $size = " · salida $(Format-Size (New-Object IO.FileInfo $output).Length)" }
    $job = Short-Args (($j.Cmd -replace '^\s*"?[^"]*?\.exe"?\s*', ''))
    $card['Eta'] = $(if ($state -eq 'paused') { "$chanName · ❚❚ en pausa desde hace $(Format-Dur ($nowMs - [long]$renderStore.paused[$id].since)) · $($j.Engine)" }
      elseif ($bp) { "$chanName · $($j.Engine) · $($bp.Text)" }
      else { "$chanName · $($j.Engine)$(if ($script) { " · $script" }) · $(Format-Dur $runMs)$size$(if ($fs -and $fs.Prog -and $fs.Prog.eta_min) { " · vídeo listo en ~$($fs.Prog.eta_min) min" })" })
    $card['Tip'] = (@($title, "Estado: $($renderInfo[$state].Label) · $($j.Engine) (PID $($p.Pid), $($pids.Count) procesos)", "Salida: $(if ($output) { $output } else { 'desconocida' })", "Carpeta: $($j.Dir)", "Orden: $job") + $(if ($fs -and $fs.Prog) { @("FORJA: $($fs.Prog.fase) · $($fs.Prog.detalle)") } else { @() })) -join "`n"
    $card['Sort'] = [long]([DateTimeOffset]$p.Created).ToUnixTimeMilliseconds()
    $card.End()
    $active.Add($card)
  }

  # 3. Lanzadores de Blender sin Blender debajo: esperan su turno (por orden de llegada)
  $waitList = @($launchers.Values | Where-Object {
      $l = $_
      $hasBlender = @(Tree-Pids $l.P.Pid | Where-Object { $renderById[$_].Name -eq 'blender.exe' }).Count
      $outer = -not @(Ancestors $l.P.Pid | Where-Object { $launchers.ContainsKey($_) }).Count
      -not $hasBlender -and $outer
    } | Sort-Object { $_.P.Created })
  $k = 0
  foreach ($l in $waitList) {
    $k++
    $p = $l.P
    $id = "wait:$($p.Pid)"
    $seenProc[$id] = $true
    $states[$id] = 'waiting'
    $fv = Forja-Video ($l.Cmd + ' ' + $l.Dir)
    $fs = if ($fv) { Forja-State $fv } else { $null }
    $rest = $l.Cmd -replace '^.*?(blender|lanza_blender|bl|lote|cola_turno)\.py"?\s*', ''
    $launcher = if ($l.Cmd -match '(blender|lanza_blender|bl|lote|cola_turno)\.py') { $matches[0] } else { 'blender.py' }
    $job = Short-Args $rest
    $title = if ($fv) { "$($fv.Mid).mp4" } else { "Blender · $job" }
    $root = if ($fs) { $fs.Dir } else { $l.Dir }
    $chan = if ($root -and $renderStore.channel.ContainsKey($root)) { [string]$renderStore.channel[$root] } elseif ($fs -and $fs.Canal) { $fs.Canal } else { Render-Channel $root ($l.Cmd + ' ' + $l.Dir) }
    $card = Get-Card $id 'wait'
    $card.Begin()
    $card['Pid'] = $p.Pid; $card['Output'] = $root; $card['Root'] = $root; $card['Title'] = $title; $card['Cmd'] = $l.Cmd; $card['Job'] = $job
    $card['Mid'] = $(if ($fv) { $fv.Mid } else { '' })
    Card-Look $card 'waiting' $chan $glyphs.wait
    $pct = if ($fs -and $fs.Prog) { [double]$fs.Prog.pct } else { -1 }
    $card['Bar1Label'] = 'Vídeo'; $card['RFrac'] = $(if ($pct -ge 0) { $pct / 100 } else { 0.0 }); $card['RText'] = $(if ($pct -ge 0) { '{0:N0} %' -f $pct } else { '?' })
    $card['Bar2Label'] = 'Turno'; $card['EFrac'] = [double](($waitList.Count - $k + 1) / [Math]::Max(1, $waitList.Count)); $card['EText'] = "#$k de $($waitList.Count)"
    $chanName = if ($chan -and $channels.Contains($chan)) { $channels[$chan].Name } else { 'Sin canal' }
    $card['Eta'] = "$chanName · esperando turno de Blender desde hace $(Format-Dur ($now - $p.Created).TotalMilliseconds) · $job"
    $card['Tip'] = (@($title, "Estado: ESPERANDO TURNO de Blender (#$k de $($waitList.Count))", "Lanzador: $launcher (PID $($p.Pid))", "Trabajo: $job", "Carpeta: $($l.Dir)") + $(if ($fs -and $fs.Prog) { @("FORJA: $($fs.Prog.fase) · $($fs.Prog.detalle)") } else { @() })) -join "`n"
    $card['Sort'] = $k
    $card.End()
    $waiting.Add($card)
  }

  # 4. Cola de vídeos de FORJA, llevada por el panel: uno en curso; los de En espera salen solos en orden; los de En pausa no
  # Si el lanzador de una terminal sigue vivo, el panel se queda su cola (el vídeo en curso sigue trabajando) para que esa terminal se pueda cerrar
  if ($lote) {
    $ql = New-Object System.Collections.Generic.List[string]; foreach ($k in @($renderStore.queue)) { if ($k) { $ql.Add([string]$k) } }
    foreach ($m in [regex]::Matches($lote.Cmd, '(\d{8}-\d{6}):(\d+)')) { $k = "$($m.Groups[1].Value):$($m.Groups[2].Value)"; if (-not $ql.Contains($k)) { $ql.Add($k) } }
    $renderStore.queue = $ql.ToArray()
    Stop-Process -Id $lote.P.Pid -Force -ErrorAction SilentlyContinue
    Save-Renders
    Log '⇄ la cola de FORJA la lleva ahora el panel: ya puedes cerrar la terminal que la lanzó' $theme.Accent2
    $lote = $null
  }
  $script:loteProc = $null
  $qkeys = New-Object System.Collections.Generic.List[string]
  foreach ($k in @($renderStore.queue)) { if ($k -and -not $qkeys.Contains([string]$k)) { $qkeys.Add([string]$k) } }
  foreach ($b in @($bridge.Values | Sort-Object { [long]$_.R.startedAt })) { $k = "$($b.Fv.Run):$($b.Fv.N)"; if (-not $qkeys.Contains($k)) { $qkeys.Add($k) } }
  $qItems = New-Object System.Collections.Generic.List[object]
  $front = New-Object System.Collections.Generic.List[string]
  foreach ($k in $qkeys) {
    if ($k -notmatch '^(\d{8}-\d{6}):(\d+)$') { continue }
    $fv = @{ Run = $matches[1]; N = [int]$matches[2]; Mid = "r$($matches[1] -replace '-', '_')_v$($matches[2])" }
    $mid = $fv.Mid
    $fs = Forja-State $fv
    $id = "queue:$mid"
    # la sesión de Claude que lo produce: lanzada desde el panel (su cmd) o por una terminal (claude -p con la ruta del vídeo)
    $sessPid = 0
    $l = $renderStore.launched[$mid]
    if ($l -and $byId.ContainsKey([int]$l.pid) -and [Math]::Abs([long]$l.created - [long]([DateTimeOffset]$byId[[int]$l.pid].Created).ToUnixTimeMilliseconds()) -lt 3000) { $sessPid = [int]$l.pid }
    elseif ($sessions.ContainsKey($mid)) { $sessPid = [int]$sessions[$mid] }
    if ($fs.Delivered -and -not $sessPid) {
      $renderStore.held.Remove($mid); $renderStore.frozenWait.Remove($mid); $renderStore.paused.Remove($id); $renderStore.retries.Remove($mid)
      continue
    }
    $held = $renderStore.held[$mid]
    if ($held -and $held.kind -eq 'frozen' -and -not $sessPid) { Thaw-Pids $renderStore.paused[$id].pids; $renderStore.paused.Remove($id); $renderStore.held[$mid] = @{ kind = 'stopped'; since = [long]$held.since; reason = 'su sesión se cerró' }; $held = $renderStore.held[$mid] }
    if ($renderStore.frozenWait.ContainsKey($mid) -and -not $sessPid) { $renderStore.frozenWait.Remove($mid) }
    $prev = if ($script:renderPrev) { $script:renderPrev[$id] } else { $null }
    if ($held) { $state = if ($held.kind -eq 'frozen') { 'paused' } else { 'stopped' } }
    elseif ($sessPid -and $renderStore.frozenWait.ContainsKey($mid)) { $state = 'queued' }
    elseif ($sessPid) { $state = 'producing'; $renderStore.crashed.Remove($mid) }
    else {
      $state = 'queued'
      if ($prev -eq 'producing') {
        # su sesión se cayó sin entregar (terminal cerrada, error...): no se pierde, vuelve el primero a En espera y se retoma
        $n = 1 + [int]$renderStore.retries[$mid]
        $renderStore.retries[$mid] = $n
        if ($n -gt 3) {
          $renderStore.held[$mid] = @{ kind = 'stopped'; since = $nowMs; reason = 'se cayó 3 veces' }; $state = 'stopped'
          Log "✖ $mid.mp4 se cayó 3 veces: pasa a En pausa" $crit
        } else {
          $renderStore.crashed[$mid] = $nowMs; $front.Add($k)
          Log "↻ $mid.mp4: su sesión se detuvo sin entregar · vuelve el primero a En espera (se retoma en 1 min)" $renderInfo.queued.Color
        }
      }
    }
    $qItems.Add(@{ Fv = $fv; Fs = $fs; B = $bridge[$mid]; Id = $id; Sess = $sessPid; State = $state; Key = $k })
  }
  # orden guardado (los que se cayeron, delante); lo entregado sale de la cola
  $order = @($front) + @($qItems | ForEach-Object { $_.Key } | Where-Object { -not $front.Contains($_) })
  $qItems = @($qItems | Sort-Object { [Array]::IndexOf($order, $_.Key) })
  if (($order -join ',') -ne (@($renderStore.queue) -join ',')) { $renderStore.queue = $order }
  Save-Renders
  $qn = 0
  foreach ($q in $qItems) {
    $fv = $q.Fv; $fs = $q.Fs; $b = $q.B; $id = $q.Id; $state = $q.State; $mid = $fv.Mid
    if ($state -eq 'queued') { $qn++ }
    $states[$id] = $state
    $seenProc[$id] = $true
    $chan = if ($fs.Canal) { $fs.Canal } elseif ($renderStore.channel.ContainsKey($fs.Dir)) { [string]$renderStore.channel[$fs.Dir] } else { '' }
    $card = Get-Card $id 'queue'
    $card.Begin()
    $card['Pid'] = 0; $card['SessPid'] = $q.Sess; $card['Output'] = $fs.Entrega; $card['Root'] = $fs.Dir; $card['Title'] = "$mid.mp4"; $card['VideoDir'] = $fs.Dir
    $card['Mid'] = $mid; $card['Run'] = $fv.Run; $card['N'] = $fv.N; $card['Canal'] = $fs.Canal; $card['Jobs'] = $null; $card['Key'] = $q.Key
    $card['Frozen'] = $renderStore.frozenWait.ContainsKey($mid) -or ($renderStore.held[$mid] -and $renderStore.held[$mid].kind -eq 'frozen')
    Card-Look $card $state $chan $glyphs.queue
    $prog = $fs.Prog
    $pct = if ($prog) { [double]$prog.pct } else { 0 }
    if (-not $prog -and $b) { $pct = [double]$b.R.rendered }
    $card['Started'] = $pct -gt 0
    $fase = if ($prog -and $prog.fase) { [string]$prog.fase } else { 'sin empezar' }
    $fi = [Array]::IndexOf($phaseOrder, $fase)
    $card['Bar1Label'] = 'Vídeo'; $card['RFrac'] = $pct / 100; $card['RText'] = '{0:N0} %' -f $pct
    $card['Bar2Label'] = 'Fase'; $card['EFrac'] = $(if ($fi -ge 0) { ($fi + 1) / $phaseOrder.Count } else { 0.0 }); $card['EText'] = $fase
    $chanName = if ($chan -and $channels.Contains($chan)) { $channels[$chan].Name } else { 'Sin canal' }
    $detail = if ($prog -and $prog.detalle) { [string]$prog.detalle } elseif ($b -and $b.R.note) { [string]$b.R.note } else { 'aún no empezado' }
    if ($b -and $b.R.title -match '·\s*(.+)$') { $detail = "$($matches[1]) · $detail" }
    $held = $renderStore.held[$mid]
    $card['Eta'] = switch ($state) {
      'producing' { "$chanName · $detail$(if ($prog -and $prog.eta_min) { " · ~$($prog.eta_min) min" })" }
      'paused' { "$chanName · ❚❚ congelado desde hace $(Format-Dur ($nowMs - [long]$held.since)) · no sale solo: clic derecho → Reanudar" }
      'stopped' { "$chanName · en pausa$(if ($held.reason) { " ($($held.reason))" }) · no sale solo: clic derecho → Reanudar · $detail" }
      default {
        $pre = if ($renderStore.crashed.ContainsKey($mid)) { 'se cayó: se retoma el primero' } elseif ($card['Frozen']) { 'congelado, espera su turno' } else { "#$qn" }
        "$chanName · $pre · $(if ($script:queueBlocker) { "la cola espera: $($script:queueBlocker) está en pausa" } else { 'sale cuando acabe el que está en curso' }) · $detail"
      }
    }
    $card['Tip'] = (@("$mid.mp4", "Estado: $($renderInfo[$state].Label) · fase $fase · $('{0:N0}' -f $pct) %", "Detalle: $detail", "Saldrá en: $($fs.Entrega)") + $(if ($q.Sess) { @("Sesión: PID $($q.Sess)") } else { @() })) -join "`n"
    $card['Sort'] = $(if ($state -eq 'producing') { -1 } else { 1000 + [Array]::IndexOf($order, $q.Key) })
    $card.End()
    if ($state -eq 'producing') { $active.Add($card) } else { $waiting.Add($card) }
  }
  # Solo uno en curso: cuando no hay ninguno, sale el primero de En espera (uno congelado se descongela; el resto se lanza)
  $producing = @($qItems | Where-Object { $_.State -eq 'producing' })
  $blocker = @()
  $script:queueBlocker = if ($blocker.Count) { "$($blocker[0].Fv.Mid).mp4" } else { '' }
  if (-not $producing.Count -and -not $blocker.Count -and (-not $script:lastAutoLaunch -or ($now - $script:lastAutoLaunch).TotalSeconds -gt 20)) {
    $next = $qItems | Where-Object { $_.State -eq 'queued' -and (-not $renderStore.crashed.ContainsKey($_.Fv.Mid) -or ($nowMs - [long]$renderStore.crashed[$_.Fv.Mid]) -ge 60000) } | Select-Object -First 1
    if ($next) {
      $script:lastAutoLaunch = $now
      $c = $renderCards[$next.Id]
      if ($renderStore.frozenWait.ContainsKey($next.Fv.Mid)) { Thaw-Production $c } else { Launch-Production $c $true }
    }
  }

  # 5. Procesos que acaban de terminar: se quedan una hora en Terminados
  if ($null -ne $script:renderPrev) {
    foreach ($k2 in @($script:renderPrev.Keys)) {
      $gone = $renderCards[$k2]
      # Solo cuenta como render terminado lo que duró más de un minuto y no es un trabajo de un vídeo de FORJA
      # (las validaciones de FORJA abren el mp4 con ffmpeg varias veces al acabar)
      if ($k2 -like 'proc:*' -and -not $states.ContainsKey($k2) -and $gone -and $script:skipDone -ne $k2 -and -not $gone['Mid'] -and ($nowMs - [long]$gone['Sort']) -ge 60000) {
        $c = $renderCards[$k2]
        $c.Begin()
        Card-Look $c 'finished' ([string]$c['Channel']) ([string]$c['Glyph'])
        $c['EFrac'] = 0.0; $c['EText'] = '—'
        $c['Eta'] = "$($c['Engine']) terminó a las $($now.ToString('HH:mm'))"
        $c['Sort'] = 0 - $nowMs
        $c.End()
        $procDone[$k2] = @{ Card = $c; Until = $now.AddHours(1) }
        Log "■ terminó: $($c['Title']) ($($c['Engine']))" $renderInfo.done.Color
      }
    }
  }
  foreach ($k2 in @($procDone.Keys)) {
    if ($procDone[$k2].Until -lt $now -or $renderStore.hidden.ContainsKey($k2)) { $procDone.Remove($k2); continue }
    $states[$k2] = 'finished'; $finished.Add($procDone[$k2].Card)
  }
  foreach ($k2 in @($renderStore.paused.Keys)) { if ($k2 -match '^(proc|wait):' -and -not $states.ContainsKey($k2)) { Thaw-Pids $renderStore.paused[$k2].pids; $renderStore.paused.Remove($k2); Save-Renders } }
  foreach ($k2 in @($renderCards.Keys)) { if (-not $states.ContainsKey($k2)) { $renderCards.Remove($k2); $renderHist.Remove($k2); $jobCpu.Remove($k2) } }

  $byMid = @{}
  foreach ($c in $active.ToArray()) { if ([string]$c['Kind'] -eq 'queue' -and $c['Mid']) { $byMid[[string]$c['Mid']] = $c } }
  foreach ($c in $waiting.ToArray()) { if ([string]$c['Kind'] -eq 'queue' -and $c['Mid']) { $byMid[[string]$c['Mid']] = $c } }
  $jobsOf = @{}
  foreach ($list in @($active, $waiting)) {
    foreach ($c in $list.ToArray()) {
      $isLive = [string]$c['Kind'] -ne 'render' -or [string]$c['State'] -in ($activeStates + 'paused')
      if ([string]$c['Kind'] -in 'proc', 'wait', 'render' -and $isLive -and $c['Mid'] -and $byMid.ContainsKey([string]$c['Mid'])) {
        [void]$list.Remove($c)
        if (-not $jobsOf.ContainsKey([string]$c['Mid'])) { $jobsOf[[string]$c['Mid']] = New-Object System.Collections.Generic.List[object] }
        $jobsOf[[string]$c['Mid']].Add($c)
      }
    }
  }
  foreach ($mid in $jobsOf.Keys) {
    $q = $byMid[$mid]; $jl = $jobsOf[$mid]
    $run = @($jl | Where-Object { $_['Kind'] -eq 'proc' } | Select-Object -First 1)
    $wts = @($jl | Where-Object { $_['Kind'] -eq 'wait' })
    $fin = @($jl | Where-Object { $_['Kind'] -eq 'render' } | Select-Object -First 1)
    $working = $fin.Count -or @($run | Where-Object { $_['State'] -ne 'paused' }).Count
    $chanName = if ($q['Channel'] -and $channels.Contains([string]$q['Channel'])) { $channels[[string]$q['Channel']].Name } else { 'Sin canal' }
    $q.Begin()
    $q['Jobs'] = $jl.ToArray()
    $queuePos = if ($q['State'] -eq 'queued') { ([string]$q['Eta'] -split ' · ')[1] } else { '' }
    # Un vídeo en cola cuyo Blender ya tiene el turno (o que ya se está renderizando) pasa a En curso
    $parts = @($chanName)
    if ($queuePos) { $parts += $queuePos }
    if ($fin.Count) {
      $f0 = $fin[0]
      $q['Bar2Label'] = 'Render'; $q['EFrac'] = [double]$f0['RFrac']; $q['EText'] = [string]$f0['RText']
      $parts += "render final: $(([string]$f0['Eta'] -split ' · ', 2)[1])"
    } elseif ($run.Count) {
      $r0 = $run[0]
      $q['Bar2Label'] = $(if ($r0['Bar1Label'] -eq 'Toma') { 'Blender' } else { 'CPU Blender' })
      $q['EFrac'] = $(if ($r0['Bar1Label'] -eq 'Toma') { [double]$r0['RFrac'] } else { [double]$r0['EFrac'] })
      $q['EText'] = $(if ($r0['Bar1Label'] -eq 'Toma') { [string]$r0['RText'] } else { [string]$r0['EText'] })
      $parts += $(if ($r0['State'] -eq 'paused') { 'Blender en pausa' } elseif ($r0['BpText']) { "Blender: $($r0['BpText'])" } else { "Blender renderizando $($r0['Job'])" })
    }
    if ($wts.Count) { $parts += "$($wts.Count) trabajo$(if ($wts.Count -ne 1) { 's' }) de Blender esperando turno ($((@($wts | ForEach-Object { [string]$_['EText'] -replace ' de \d+$', '' })) -join ', '))" }
    if (-not $run.Count -and -not $fin.Count -and $q['State'] -eq 'producing') { $parts += ([string]$q['Eta'] -split ' · ', 2)[1] }
    $q['Eta'] = $parts -join ' · '
    $q['Tip'] = ([string]$q['Tip']) + "`n" + ((@($jl | ForEach-Object { "Blender: $($_['StateLabel']) · $($_['Job'])$(if ($_['BpText']) { " · $($_['BpText'])" })" })) -join "`n")
    $q.End()
  }
  $pausedList = New-Object System.Collections.Generic.List[object]
  foreach ($lst in @($active, $waiting)) { foreach ($c in $lst.ToArray()) { if ([string]$c['State'] -in 'paused', 'stopped') { [void]$lst.Remove($c); $pausedList.Add($c) } } }
  $pau = @($pausedList | Sort-Object { [long]$_['Sort'] })
  Sync-Items $renderPausedItems $pau
  $ui.RenderPausedHead.Visibility = $(if ($pau.Count) { 'Visible' } else { 'Collapsed' })
  $act = @($active | Sort-Object { [long]$_['Sort'] })
  $wai = @($waiting | Sort-Object { if ($_['Kind'] -eq 'wait') { [long]$_['Sort'] } else { 100000 + [long]$_['Sort'] } })
  $finSeen = @{}
  $fin = @($finished | Sort-Object { [long]$_['Sort'] } | Where-Object { $t0 = ([string]$_['Title']) -replace '\.render(\.\w+)$', '$1'; if ($finSeen.ContainsKey($t0)) { $false } else { $finSeen[$t0] = $true; $true } } | Select-Object -First 10)
  Sync-Items $renderActiveItems $act
  Sync-Items $renderWaitItems $wai
  Sync-Items $renderDoneItems $fin
  $ui.NoRenders.Visibility = $(if ($act.Count) { 'Collapsed' } else { 'Visible' })
  $ui.RenderWaitHead.Visibility = $(if ($wai.Count) { 'Visible' } else { 'Collapsed' })
  $ui.RenderDoneHead.Visibility = $(if ($fin.Count) { 'Visible' } else { 'Collapsed' })
  $pausedN = $pau.Count
  $running = $act.Count
  $turnN = @($wai | Where-Object { $_['Kind'] -eq 'wait' }).Count
  $queueN = $wai.Count - $turnN
  $ui.RenderSummary.Text = "$running en curso · $($wai.Count) en espera$(if ($pausedN) { " · $pausedN en pausa" }) · $(@($fin | Where-Object { $_['State'] -in 'done', 'finished' }).Count) terminados"
  $ui.RenderWaitSummary.Text = (@($(if ($turnN) { "$turnN esperan turno de Blender" }), $(if ($queueN) { "$queueN en la cola de FORJA" })) | Where-Object { $_ }) -join ' · '
  $ui.NavRenderCount.Text = "$running"
  $ui.NavRenderDot.Visibility = $(if ($running) { 'Visible' } else { 'Collapsed' })
  $ui.NavRenderDot.Fill = Brush-Cached $renderInfo.rendering.Color

  if ($null -ne $script:renderPrev) {
    foreach ($k2 in $states.Keys) {
      $old = $script:renderPrev[$k2]; $new = $states[$k2]; $c = $renderCards[$k2]
      if (-not $c -or $old -eq $new) { continue }
      if (-not $old -and $new -in $activeStates) { Log "🎬 nuevo render: $($c['Title'])$(if ($c['Engine']) { " ($($c['Engine']))" })" $renderInfo.rendering.Color }
      elseif ($old -eq 'queued' -and $new -eq 'producing') { Log "▶ FORJA empieza: $($c['Title'])" $renderInfo.producing.Color }
      elseif ($old -and $new -eq 'done') { Log "✔ render terminado: $($c['Title'])" $renderInfo.done.Color; if ($settings.soundDone) { [System.Media.SystemSounds]::Asterisk.Play() } }
      elseif ($old -and $new -eq 'error') { Log "✖ render con error: $($c['Title'])" $renderInfo.error.Color }
      elseif ($old -and $new -eq 'stale') { Log "⚠ render cortado: $($c['Title'])" $renderInfo.stale.Color }
    }
  }
  $script:renderPrev = $states
  $script:skipDone = $null
}

# --- Control de la producción de FORJA desde el panel -------------------------------------------
function Claude-Exe {
  $c = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
  if ([IO.File]::Exists($c)) { return $c }
  $g = Get-Command claude -ErrorAction SilentlyContinue
  if ($g) { return $g.Source }
  'claude'
}
# El mismo encargo que daba produccion_lote/lanzar_lote.py: continuar el vídeo donde se quedó y hacer UN solo render final
function Forja-Prompt($item) {
  $run = [string]$item['Run']; $n = [int]$item['N']; $mid = [string]$item['Mid']; $canal = [string]$item['Canal']
  $V = Join-Path $forjaRoot "runs\$run\video$n"; $P = Join-Path $V '08_prompt'
  $saved = Join-Path $P 'prompt_lote.txt'
  if ([IO.File]::Exists($saved)) { return [IO.File]::ReadAllText($saved) }
  $entrega = Join-Path $forjaRoot "runs\$run\ENTREGA\$mid.mp4"
  $t = @'
Lee el archivo __P__\prompt.txt (vídeo __N__ del flujo __RUN__, canal __CANAL__, id en el motor __MID__) y ejecuta su encargo (bloque del apartado 3), CON ESTOS CAMBIOS QUE MANDAN SOBRE ÉL:

1. Este vídeo puede estar ya a medias: sesiones anteriores pudieron trabajar en él (la última pudo detenerse a propósito o por un error).
   Lee primero el trabajo previo: __V__\08_produccion, 09_produccion o 10_produccion (ESTADO.md / PROGRESO.md / RELEVO*.md si existen),
   __P__\progreso.json, motor\src\videos\__MID__ y motor\public\videos\__MID__. Continúa desde ahí; no rehagas lo que ya esté hecho.
2. Puede haber renders de esa sesión TODAVÍA EN MARCHA (Blender vía herramientas/blender.py, render.py/Remotion). Compruébalo
   (Get-CimInstance Win32_Process / tasklist buscando tu __MID__ o tus scripts) y, si los hay, NO los dupliques ni los mates: espera a que
   acaben vigilando sus archivos de salida con comandos en segundo plano.
3. REGLA DEL USUARIO, OBLIGATORIA: UN SOLO BORRADOR POR VÍDEO. Nada de rondas de prueba y corrección: el usuario lo revisará a mano y
   decidirá qué cambiar. Cuando el material (audio, 3D, montaje) esté completo, haz UN ÚNICO render del vídeo, con calidad de entrega
   (render.py sin --borrador) a __ENTREGA__. Si un render se cortó, repetir la misma orden lo reanuda desde los trozos ya hechos.
   - Si ya existe un MP4 hecho con el material definitivo (en ENTREGA o un borrador*.mp4 sin material provisional), NO renderices otro:
     ese es el borrador; cópialo a __ENTREGA__ si no está ahí.
   - Si ya hay un render final de este vídeo en marcha, ese es el único: espera a que acabe.
   - Después pasa validar.py y retencion.py SOLO para informar. NO corrijas ni vuelvas a renderizar aunque algo falle: anótalo.
4. Al terminar: forja.py plan-estado __RUN__ __N__ producido, y escribe __V__\ENTREGADO.md con la ruta del MP4, las medidas y una lista
   clara de lo que ves flojo o que se podría cambiar (para que el usuario decida).
5. Los vídeos se producen DE UNO EN UNO: ahora solo trabajas tú, pero pueden quedar en cola renders de Blender de otros vídeos lanzados antes
   (i7-1355U sin GPU). Blender SIEMPRE con herramientas/blender.py (va por turnos). No termines tu sesión hasta tener el MP4 y ENTREGADO.md
   (o un bloqueo real anotado): espera los renders largos con comandos en segundo plano.
   Trabaja sin preguntar: nadie responderá. Si algo te bloquea de verdad, anótalo en ENTREGADO.md.
6. PANEL DE PROGRESO (obligatorio): cada vez que cambies de fase o avances algo notable, sobrescribe __P__\progreso.json (UTF-8) con
   {"fase": "<revisando|audio|3d|montaje|render|entregado|bloqueado>", "pct": <0-100 del vídeo completo>, "detalle": "<1 frase>", "eta_min": <minutos o null>}
   Al terminar: fase "entregado" y pct 100 (o "bloqueado" con el motivo).
'@
  $t.Replace('__P__', $P).Replace('__V__', $V).Replace('__N__', "$n").Replace('__RUN__', $run).Replace('__CANAL__', $canal).Replace('__MID__', $mid).Replace('__ENTREGA__', $entrega)
}
# Lanza (o continúa) la producción de un vídeo en una sesión de Claude sin ventana, que no depende de ninguna terminal ni del monitor
function Launch-Production($item, [bool]$auto = $false) {
  if (-not $item) { return }
  $mid = [string]$item['Mid']
  if ([int]$item['SessPid']) { Log "$mid.mp4 ya tiene su sesión abierta" $warn; return }
  if (-not $auto) {
    $other = @($renderCards.Values | Where-Object { $_['Kind'] -eq 'queue' -and $_['State'] -eq 'producing' -and $_['Mid'] -ne $mid })
    # lanzar a mano vuelve a poner la cola en marcha aunque haya algo en pausa
    foreach ($hk in @($renderStore.held.Keys)) { $renderStore.held[$hk].blocks = $false }
    if ($other.Count -and -not (Confirm-Dialog 'Ya hay un vídeo en curso' "$($other[0]['Title']) está en curso. Si lanzas $mid.mp4 a la vez irán los dos más lentos (comparten CPU y el turno de Blender). Si no, déjalo en En espera: saldrá solo al acabar el otro." 'Lanzar igualmente')) { return }
  }
  $P = Join-Path ([string]$item['VideoDir']) '08_prompt'
  try {
    [void][IO.Directory]::CreateDirectory($P)
    $pf = Join-Path $P 'prompt_panel.txt'
    [IO.File]::WriteAllText($pf, (Forja-Prompt $item), (New-Object Text.UTF8Encoding $false))
    $claude = Claude-Exe
    $name = "FORJA $($item['Canal']) v$($item['N'])"
    $cmdArgs = "/s /c `" set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0&& (type `"$pf`" | `"$claude`" -p --model claude-opus-5-5 --permission-mode auto --output-format stream-json --verbose -n `"$name`" >> `"$(Join-Path $P 'sesion.jsonl')`" 2>> `"$(Join-Path $P 'sesion.err')`") `""
    $pr = Start-Process cmd.exe -ArgumentList $cmdArgs -WorkingDirectory $forjaRoot -WindowStyle Hidden -PassThru
    $renderStore.launched[$mid] = @{ pid = $pr.Id; created = ([DateTimeOffset]$pr.StartTime).ToUnixTimeMilliseconds(); at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $renderStore.held.Remove($mid)
    if (-not $auto) { $renderStore.retries.Remove($mid); $renderStore.crashed.Remove($mid) }
    Save-Renders
    Log "▶ $(if ($item['Started']) { 'continúa' } else { 'empieza' }) la producción de $mid.mp4$(if ($auto) { ' (le tocaba en la cola)' })" $renderInfo.producing.Color
  } catch { Log "no se pudo lanzar $mid.mp4: $($_.Exception.Message)" $crit }
  if (-not $auto) { Refresh }
}
# Todo lo que trabaja para un vídeo: su sesión de Claude (con todo lo que cuelga) y sus Blender, esperas y render final
function Production-Pids($item) {
  $all = New-Object System.Collections.Generic.List[int]
  if ([int]$item['SessPid']) { foreach ($x in (Tree-Pids ([int]$item['SessPid']) $true)) { $all.Add($x) } }
  foreach ($c in @($renderCards.Values)) {
    if ($c['Mid'] -eq $item['Mid'] -and $c['Kind'] -in 'proc', 'wait', 'render' -and $c['State'] -notin 'done', 'error', 'stale', 'finished') { foreach ($x in (Render-Pids $c)) { $all.Add($x) } }
  }
  @($all | Select-Object -Unique)
}
function Any-Producing([string]$except) { [bool]@($renderCards.Values | Where-Object { $_['Kind'] -eq 'queue' -and $_['State'] -eq 'producing' -and $_['Mid'] -ne $except }).Count }
# Pausar: el que está en curso se congela tal cual (no pierde nada) y deja paso al siguiente de En espera; uno de En espera pasa a En pausa
function Pause-Production($item) {
  $mid = [string]$item['Mid']; $id = [string]$item['Id']
  $now0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if ($item['State'] -eq 'producing') {
    $nextQ = @($renderCards.Values | Where-Object { $_['Kind'] -eq 'queue' -and $_['State'] -eq 'queued' } | Sort-Object { [long]$_['Sort'] } | Select-Object -First 1)
    if (-not (Confirm-Dialog 'Pausar el vídeo en curso' "$($item['Title']) se congelará tal cual y pasará a En pausa (no pierde nada).$(if ($nextQ.Count) { " Como no quedará ninguno en curso, saldrá $($nextQ[0]['Title']) de En espera." })" 'Pausar')) { return }
    $pids = @(Production-Pids $item)
    $ok = 0
    foreach ($p in $pids) { if ([TaskMon.Native]::Suspend($p)) { $ok++ } }
    if (-not $ok) { Log "no se pudo pausar $($item['Title'])" $crit; return }
    $renderStore.paused[$id] = @{ since = $now0; pids = $pids }
    $renderStore.held[$mid] = @{ kind = 'frozen'; since = $now0 }
    Log "❚❚ $($item['Title']) en pausa ($ok procesos congelados) · sale el siguiente de En espera" $renderInfo.paused.Color
  } elseif ($item['Frozen']) {
    $renderStore.frozenWait.Remove($mid)
    $renderStore.held[$mid] = @{ kind = 'frozen'; since = $now0 }
    Log "❚❚ $($item['Title']) pasa a En pausa" $renderInfo.paused.Color
  } else {
    $renderStore.held[$mid] = @{ kind = 'stopped'; since = $now0; reason = 'pausado a mano' }
    Log "❚❚ $($item['Title']) pasa a En pausa: no saldrá hasta que lo reanudes" $renderInfo.stopped.Color
  }
  $renderStore.crashed.Remove($mid)
  Save-Renders
  Refresh
}
function Thaw-Production($item) {
  $mid = [string]$item['Mid']; $id = [string]$item['Id']
  $entry = $renderStore.paused[$id]
  $pids = @(@($entry.pids) + @(Production-Pids $item) | Where-Object { $_ } | Select-Object -Unique)
  Thaw-Pids $pids
  $renderStore.paused.Remove($id); $renderStore.frozenWait.Remove($mid); $renderStore.held.Remove($mid)
  Save-Renders
  Log "▶ $($item['Title']) sigue donde se quedó" $renderInfo.resuming.Color
}
# Reanudar uno de En pausa: si no hay ninguno en curso sale ya; si lo hay, pasa a En espera y sale cuando le toque
function Resume-Production($item) {
  $mid = [string]$item['Mid']
  $held = $renderStore.held[$mid]
  $renderStore.held.Remove($mid); $renderStore.retries.Remove($mid)
  $busy = Any-Producing $mid
  if ($held -and $held.kind -eq 'frozen' -and [int]$item['SessPid']) {
    if ($busy) { $renderStore.frozenWait[$mid] = $true; Save-Renders; Log "$($item['Title']) pasa a En espera (sigue congelado hasta su turno)" $renderInfo.queued.Color }
    else { Thaw-Production $item }
  } else {
    Save-Renders
    if ($busy) { Log "$($item['Title']) pasa a En espera: saldrá cuando acabe el que está en curso" $renderInfo.queued.Color }
    else { $script:lastAutoLaunch = Get-Date; Launch-Production $item $true }
  }
  Refresh
}
function Stop-Production($item) {
  if (-not (Confirm-Dialog 'Detener la producción' "Se cerrará la sesión que produce $($item['Title']) y sus renders en marcha. Lo hecho no se pierde: queda En pausa y «Reanudar» sigue desde ahí." 'Detener')) { return }
  $pids = @(Production-Pids $item)
  Thaw-Pids $pids
  foreach ($p in $pids) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
  $mid = [string]$item['Mid']
  $renderStore.paused.Remove([string]$item['Id']); $renderStore.launched.Remove($mid); $renderStore.frozenWait.Remove($mid); $renderStore.crashed.Remove($mid)
  $renderStore.held[$mid] = @{ kind = 'stopped'; since = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); reason = 'detenido a mano' }
  Save-Renders
  Log "■ $($item['Title']) detenido · queda En pausa ($($pids.Count) procesos cerrados)" $renderInfo.stopped.Color
  Refresh
}
function Move-ToFront($item) {
  $k = [string]$item['Key']
  $renderStore.queue = @(@($k) + @(@($renderStore.queue) | Where-Object { $_ -ne $k }))
  Save-Renders
  Log "⇡ $($item['Title']) es el primero de En espera" $renderInfo.queued.Color
  Refresh
}
function Remove-FromQueue($item) {
  $k = [string]$item['Key']; $mid = [string]$item['Mid']
  $renderStore.queue = @(@($renderStore.queue) | Where-Object { $_ -ne $k })
  $renderStore.held.Remove($mid); $renderStore.crashed.Remove($mid); $renderStore.retries.Remove($mid)
  Save-Renders
  Log "quitado de la cola: $($item['Title'])" $theme.Accent2
  Refresh
}
# Un render con progreso que quedó en pausa (por un error) o cortado: se relanza con la misma orden y sigue desde sus trozos
function Relaunch-Render($item) {
  $r = $null
  try { $r = [IO.File]::ReadAllText([string]$item['Path']) | ConvertFrom-Json } catch {}
  if (-not $r -or -not $r.resume) { Log "$($item['Title']) no guardó cómo reanudarse (render antiguo)" $warn; return }
  if ($r.pid -and $renderById.ContainsKey([int]$r.pid)) { Log "$($item['Title']) sigue vivo y reintentará solo" $theme.Accent2; return }
  foreach ($p in $renderById.Values) {
    if ($p.Name -eq 'node.exe' -and (Proc-Info $p).Cmd -like "*$([IO.Path]::GetFileName([string]$r.output))*") { Log "$($item['Title']) ya se está renderizando otra vez" $theme.Accent2; return }
  }
  $a = @($r.resume.args)
  if ([string]$r.output -like '*.render.mp4' -and -not @($a | Where-Object { $_ -like '--rename-to=*' }).Count) { $a += "--rename-to=$(([string]$r.output) -replace '\.render\.mp4$', '.mp4')" }
  $argStr = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  try {
    Start-Process -FilePath ([string]$r.resume.node) -ArgumentList $argStr -WorkingDirectory ([string]$r.resume.cwd) -WindowStyle Hidden | Out-Null
    Log "▶ reanudando el render de $($item['Title']) desde su último trozo" $renderInfo.resuming.Color
  } catch { Log "no se pudo reanudar $($item['Title']): $($_.Exception.Message)" $crit }
  Refresh
}

# --- Menú del clic derecho de un render
function Render-MenuInfo($menu, $item) {
  $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '14,6,14,6'; $sp.MaxWidth = 400
  $head = New-Object System.Windows.Controls.StackPanel; $head.Orientation = 'Horizontal'
  if ($item['Cover']) {
    $cv = New-Object System.Windows.Controls.Border; $cv.Width = 34; $cv.Height = 34; $cv.CornerRadius = 6; $cv.Margin = '0,0,10,0'
    $ib = New-Object System.Windows.Media.ImageBrush $item['Cover']; $ib.Stretch = 'UniformToFill'; $cv.Background = $ib
    [void]$head.Children.Add($cv)
  }
  $hs = New-Object System.Windows.Controls.StackPanel; $hs.VerticalAlignment = 'Center'
  $title = New-Text ([string]$item['Title']) $theme.Bright 13.5 'SemiBold'; $title.TextTrimming = 'CharacterEllipsis'; $title.MaxWidth = 340
  [void]$hs.Children.Add($title)
  $chip = New-Object System.Windows.Controls.StackPanel; $chip.Orientation = 'Horizontal'; $chip.Margin = '0,2,0,0'
  $col = Brush-Cached $item['StateColor']
  $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = $col; $dot.Margin = '0,0,7,0'; $dot.VerticalAlignment = 'Center'
  [void]$chip.Children.Add($dot)
  [void]$chip.Children.Add((New-Text ([string]$item['StateLabel']) $col 11.5 'Bold'))
  [void]$hs.Children.Add($chip)
  [void]$head.Children.Add($hs)
  [void]$sp.Children.Add($head)
  $tipLines = @(([string]$item['Tip']) -split "`n" | Select-Object -Skip 2)
  $rows = @(foreach ($line in $tipLines) { if ($line -match '^([^:]{2,12}):\s*(.*)$') { , @($matches[1], $matches[2]) } })
  $rows += , @('Ahora', [string]$item['Eta'])
  $grid = New-Object System.Windows.Controls.Grid; $grid.Margin = '0,8,0,0'
  $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
  $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $k = New-Text $rows[$i][0] $theme.Dim 11.5; $k.Margin = '0,1,12,1'; $k.VerticalAlignment = 'Top'
    $v = New-Text ([string]$rows[$i][1]) $theme.Text 11.5; $v.Margin = '0,1,0,1'; $v.TextWrapping = 'Wrap'; $v.MaxHeight = 34; $v.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetRow($k, $i); [System.Windows.Controls.Grid]::SetRow($v, $i); [System.Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$grid.Children.Add($k); [void]$grid.Children.Add($v)
  }
  [void]$sp.Children.Add($grid)
  Menu-Static $menu $sp
}
function New-ThemedMenu {
  $menu = New-Object System.Windows.Controls.ContextMenu
  foreach ($k in $theme.Keys) { if ($k -ne 'Name') { $menu.Resources[$k] = [System.Windows.Media.Brush](Brush $theme[$k]) } }
  $menu.Resources['Radius'] = [System.Windows.CornerRadius]::new($style.Radius)
  $menu.Style = $window.FindResource('TermMenu')
  $menu
}
$onRenderMenu = [System.Windows.Input.MouseButtonEventHandler]{
  param($sender, $e)
  $item = $e.OriginalSource.DataContext
  if ($item -isnot [TaskMon.Card] -or -not $item['Kind']) { return }
  $e.Handled = $true
  $menu = New-ThemedMenu
  Render-MenuInfo $menu $item
  Menu-Separator $menu
  $st = [string]$item['State']; $kind = [string]$item['Kind']
  if ($kind -eq 'queue') {
    switch ($st) {
      'producing' { Menu-Entry $menu 'Pausar (se congela y sale el siguiente)' 'x-qpause' $item; Menu-Entry $menu 'Detener' 'x-qstop' $item }
      'queued' {
        Menu-Entry $menu 'Lanzar ahora' 'x-qlaunch' $item
        if ([string]$item['Key'] -ne [string]@($renderStore.queue)[0]) { Menu-Entry $menu 'Subir al primer puesto' 'x-qfront' $item }
        Menu-Entry $menu 'Pasar a En pausa' 'x-qpause' $item
      }
      default { Menu-Entry $menu 'Reanudar' 'x-qresume' $item; if ($st -eq 'paused') { Menu-Entry $menu 'Detener' 'x-qstop' $item } }
    }
    foreach ($jb in @($item['Jobs'])) {
      if ($jb -and $jb['Kind'] -eq 'render' -and $jb['State'] -eq 'paused' -and $jb['CanResume']) { Menu-Entry $menu 'Reanudar su render final (sigue desde el último trozo)' 'r-resume' $jb }
    }
  } elseif ($kind -in 'render', 'proc') {
    if ($renderStore.paused.ContainsKey([string]$item['Id'])) { Menu-Entry $menu 'Reanudar el render' 'r-resume' $item }
    elseif ($st -in 'bundling', 'rendering', 'encoding', 'muxing', 'resuming') { Menu-Entry $menu "Pausar el render$(if ($item['Blender'] -or $item['Engine'] -eq 'Blender') { ' (Blender)' })" 'r-pause' $item }
    elseif ($kind -eq 'render' -and $st -in 'paused', 'stale', 'error' -and $item['CanResume']) { Menu-Entry $menu 'Reanudar el render (sigue desde el último trozo)' 'r-resume' $item }
  }
  Menu-Entry $menu 'Abrir la ubicación del mp4' 'r-folder' $item
  if ($st -in 'done', 'finished' -and [IO.File]::Exists([string]$item['Output'])) { Menu-Entry $menu 'Reproducir el vídeo' 'r-play' $item }
  if ($kind -eq 'queue' -and [IO.File]::Exists((Join-Path ([string]$item['VideoDir']) 'ENTREGADO.md'))) { Menu-Entry $menu 'Ver ENTREGADO.md' 'x-entregado' $item }
  if ($kind -in 'render', 'queue') { Menu-Entry $menu 'Copiar la ruta del vídeo' 'r-copy' $item }
  if ($kind -eq 'render' -and $item['Session'] -and ($itemsByPid.Values | Where-Object { $_['SessionId'] -eq $item['Session'] })) { Menu-Entry $menu 'Ir a la sesión de Claude que lo lanzó' 'r-session' $item }
  Menu-Separator $menu
  if ($kind -eq 'queue') { if ($st -in 'queued', 'stopped' -and -not $item['Frozen']) { Menu-Entry $menu 'Quitar de la cola' 'x-qremove' $item } }
  elseif ($st -in 'done', 'error', 'stale', 'finished') { Menu-Entry $menu 'Quitar de la lista' 'r-hide' $item }
  elseif ($kind -eq 'wait') { Menu-Entry $menu 'Quitar de la cola de Blender' 'r-cancel' $item }
  else { Menu-Entry $menu 'Cancelar el render' 'r-cancel' $item }
  $menu.PlacementTarget = $e.OriginalSource
  $menu.Placement = 'MousePoint'
  $menu.IsOpen = $true
  $script:lastMenu = $menu
}
foreach ($list in @($ui.RenderActive, $ui.RenderWait, $ui.RenderPaused, $ui.RenderDone)) {
  $list.AddHandler([System.Windows.UIElement]::PreviewMouseRightButtonUpEvent, $onRenderMenu)
  $list.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent, [System.Windows.Input.MouseButtonEventHandler]{
    param($sender, $e)
    $item = $e.OriginalSource.DataContext
    if ($e.ClickCount -eq 2 -and $item -is [TaskMon.Card] -and $item['Kind']) { Open-RenderFolder $item; $e.Handled = $true }
  }, $true)
}

# --- Administrador de tareas: los programas de fuera de Claude se pueden cerrar (los del sistema no)
$protectedNames = @('csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe', 'lsass.exe', 'smss.exe', 'svchost.exe', 'System', 'Registry', 'dwm.exe',
  'fontdrvhost.exe', 'Memory Compression', 'MsMpEng.exe', 'NisSrv.exe', 'MpDefenderCoreService.exe', 'SecurityHealthService.exe', 'SecurityHealthSystray.exe',
  'audiodg.exe', 'sihost.exe', 'ctfmon.exe', 'spoolsv.exe', 'WUDFHost.exe', 'LsaIso.exe', 'explorer.exe', 'conhost.exe', 'dllhost.exe', 'RuntimeBroker.exe',
  'taskhostw.exe', 'StartMenuExperienceHost.exe', 'ShellExperienceHost.exe', 'SearchHost.exe', 'SearchIndexer.exe', 'TextInputHost.exe', 'smartscreen.exe',
  'SgrmBroker.exe', 'WmiPrvSE.exe', 'unsecapp.exe', 'Idle', 'vmmem', 'vmmemWSL', 'MemCompression', 'igfxEM.exe', 'atiesrxx.exe', 'NVDisplay.Container.exe')
$appsInWindows = @('notepad.exe', 'mspaint.exe', 'write.exe', 'charmap.exe', 'magnify.exe', 'osk.exe', 'SnippingTool.exe', 'mstsc.exe', 'cmd.exe', 'powershell.exe', 'regedit.exe', 'taskmgr.exe')
$otherCpu = @{}   # nombre -> @(cpu acumulada, ms)
function Update-Others($procs, $exclude, [long]$nowMs) {
  $list = [TaskMon.Native]::TopOthers($procs, $exclude, 10)
  $byPid = @{}; foreach ($p in $procs) { $byPid[$p.Pid] = $p }
  foreach ($o in $list) {
    $sum = 0.0; $first = $null
    foreach ($x in $o.Pids) { $q = $byPid[$x]; if ($q) { $sum += $q.CpuTime / 1e7; if (-not $first) { $first = $q } } }
    $prev = $otherCpu[$o.Key]; $otherCpu[$o.Key] = @($sum, $nowMs)
    $o.Cpu = $(if ($prev -and $nowMs -gt $prev[1]) { '{0:N0} % CPU' -f [Math]::Max(0.0, ($sum - $prev[0]) / (($nowMs - $prev[1]) / 1000.0) / $cores * 100) } else { '' })
    $path = if ($first) { [TaskMon.Native]::ImagePath($first.Pid, $first.Created) } else { '' }
    $o.Path = $path
    $inWindows = $path -and $path.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase) -and $o.Key -notin $appsInWindows
    $o.Protected = $o.Key -in $protectedNames -or $inWindows -or -not $path
    $o.Mark = $(if ($o.Protected) { [string][char]0xE72E } else { '' })
    $o.Tip = "$($o.Key) · $($o.Count) proceso$(if ($o.Count -ne 1) { 's' }) · $($o.Mem)`n$(if ($path) { $path } else { 'ruta no accesible (proceso del sistema o con más permisos)' })`n$(if ($o.Protected) { 'Protegido: es del sistema y no se cierra desde aquí' } else { 'Clic derecho: cerrar, forzar el cierre o abrir su carpeta' })"
  }
  $ui.Others.ItemsSource = $list
  $ui.Others2.ItemsSource = $list
}
function Close-Other($o, [bool]$force) {
  if ($o.Protected) { Log "$($o.Key) es del sistema: no se cierra" $warn; return }
  $pids = @($o.Pids | Where-Object { $_ -ne $PID })
  if ($force) {
    if (-not (Confirm-Dialog 'Forzar el cierre' "Se cerrarán a la fuerza $($pids.Count) procesos de $($o.Key). Lo que no esté guardado se perderá." 'Forzar cierre')) { return }
    $n = 0
    foreach ($x in $pids) { try { Stop-Process -Id $x -Force -ErrorAction Stop; $n++ } catch {} }
    Log "✖ $($o.Key): $n de $($pids.Count) procesos cerrados a la fuerza" $crit
  } else {
    $n = 0
    foreach ($x in $pids) { try { $gp = Get-Process -Id $x -ErrorAction Stop; if ($gp.MainWindowHandle -ne [IntPtr]::Zero -and $gp.CloseMainWindow()) { $n++ } } catch {} }
    if ($n) { Log "⏻ pidiendo a $($o.Key) que se cierre ($n ventana$(if ($n -ne 1) { 's' }))" $theme.Accent2 }
    else { Log "$($o.Key) no tiene ventanas que cerrar: usa «Forzar cierre»" $warn }
  }
  $ui.Others.ItemsSource = $null
  $ui.Others2.ItemsSource = $null
}
$onOtherMenu = [System.Windows.Input.MouseButtonEventHandler]{
  param($sender, $e)
  $o = $e.OriginalSource.DataContext
  if ($o -isnot [TaskMon.Other]) { return }
  $e.Handled = $true
  $menu = New-ThemedMenu
  $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '14,6,14,6'; $sp.MaxWidth = 400
  [void]$sp.Children.Add((New-Text ([string]$o.Key) $theme.Bright 13.5 'SemiBold'))
  $sub = New-Text "$($o.Count) proceso$(if ($o.Count -ne 1) { 's' }) · $($o.Mem)$(if ($o.Cpu) { " · $($o.Cpu)" })" $theme.Soft 11.5; $sub.Margin = '0,2,0,2'
  [void]$sp.Children.Add($sub)
  $pt = New-Text $(if ($o.Path) { [string]$o.Path } else { 'ruta no accesible' }) $theme.Dim 11; $pt.TextWrapping = 'Wrap'
  [void]$sp.Children.Add($pt)
  if ($o.Protected) { $pr = New-Text 'Proceso del sistema: protegido, no se cierra desde aquí' (Brush-Cached $warn) 11.5 'SemiBold'; $pr.Margin = '0,6,0,0'; [void]$sp.Children.Add($pr) }
  Menu-Static $menu $sp
  Menu-Separator $menu
  if (-not $o.Protected) {
    Menu-Entry $menu 'Cerrar (como con la X de su ventana)' 'o-close' $o
    Menu-Entry $menu 'Forzar el cierre' 'o-kill' $o
    Menu-Separator $menu
  }
  if ($o.Path) { Menu-Entry $menu 'Abrir la ubicación del archivo' 'o-folder' $o; Menu-Entry $menu 'Copiar la ruta' 'o-copy' $o }
  $menu.PlacementTarget = $e.OriginalSource
  $menu.Placement = 'MousePoint'
  $menu.IsOpen = $true
  $script:lastMenu = $menu
}
foreach ($ol in @($ui.Others, $ui.Others2)) { $ol.AddHandler([System.Windows.UIElement]::PreviewMouseRightButtonUpEvent, $onOtherMenu) }
function Extra-Action([string]$action, $item) {
  switch ($action) {
    'x-qlaunch' { Launch-Production $item }
    'x-qpause' { Pause-Production $item }
    'x-qresume' { Resume-Production $item }
    'x-qstop' { Stop-Production $item }
    'x-qremove' { Remove-FromQueue $item }
    'x-qfront' { Move-ToFront $item }
    'x-copycmd' { [System.Windows.Clipboard]::SetText([string]$item['Cmd']); Log '⧉ orden copiada' $theme.Accent2 }
    'x-videodir' { Start-Process explorer.exe -ArgumentList "`"$($item['VideoDir'])`"" }
    'x-entregado' { Start-Process -FilePath (Join-Path ([string]$item['VideoDir']) 'ENTREGADO.md') }
    'o-close' { Close-Other $item $false }
    'o-kill' { Close-Other $item $true }
    'o-folder' { Start-Process explorer.exe -ArgumentList "/select,`"$($item.Path)`"" }
    'o-copy' { [System.Windows.Clipboard]::SetText([string]$item.Path); Log "⧉ ruta copiada: $($item.Path)" $theme.Accent2 }
  }
}

# Navegación de la pestaña de inicio
function Set-HomeTab([string]$tab) {
  $isRender = $tab -eq 'render'
  $ui.MainScroll.Visibility = $(if ($isRender) { 'Collapsed' } else { 'Visible' })
  $ui.RenderScroll.Visibility = $(if ($isRender) { 'Visible' } else { 'Collapsed' })
  if ($settings.homeTab -ne $tab) { $settings.homeTab = $tab; Save-Settings }
}
$ui.NavTasks.Add_Checked({ Set-HomeTab 'tasks' })
$ui.NavRender.Add_Checked({ Set-HomeTab 'render' })
if ($settings.homeTab -eq 'render') { $ui.NavRender.IsChecked = $true } else { Set-HomeTab 'tasks' }

# Memoria: se recorta poco después de cada cosa que suelta memoria y, por si acaso, cada 3 minutos
$trimTimer = New-Object System.Windows.Threading.DispatcherTimer
$trimTimer.Interval = [TimeSpan]::FromSeconds(4)
$trimTimer.Add_Tick({ $trimTimer.Stop(); [TaskMon.Native]::Trim() })
function Trim-Soon { $trimTimer.Stop(); $trimTimer.Start() }
$trimEvery = New-Object System.Windows.Threading.DispatcherTimer
$trimEvery.Interval = [TimeSpan]::FromMinutes(3)
$trimEvery.Add_Tick({ if (-not $ui.StageBtn.IsChecked) { [TaskMon.Native]::Trim() } })

# Latido: el mod mira este archivo para no lanzar PowerShell si la ventana ya está abierta
function Beat { try { [IO.File]::WriteAllText($aliveFile, "$PID") } catch {} }

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([double]$settings.refreshSec)
$timer.Add_Tick({
  $script:tick++
  Beat
  # Minimizada no se ve: se refresca una de cada cinco vueltas
  if ($window.WindowState -eq 'Minimized' -and $script:tick % 5 -ne 0) { return }
  Refresh
  Apply-Dock $false
})
$window.Add_ContentRendered({
  Log "claude-task-monitor v$version · estilo $($style.Name)"
  if ($paused.Count) { Log "$($paused.Count) sesiones siguen en pausa desde la última vez" $warn }
  Beat
  Refresh
  $timer.Start()
  Apply-Sprites
  Apply-Dock $true
  # Lo de arrancar (compilar, leer el XAML...) ya no hace falta: fuera de la memoria
  $trimTimer.Interval = [TimeSpan]::FromSeconds(15); Trim-Soon; $trimTimer.Interval = [TimeSpan]::FromSeconds(4)
  $trimEvery.Start()
})
$window.Add_StateChanged({
  if ($window.WindowState -eq 'Minimized') { $pulse.Stop(); Trim-Soon } else { $pulse.Start(); Refresh }
  if ($settings.dockTerminal -and $window.WindowState -ne 'Minimized') { $dockTimer.Stop(); $dockTimer.Start() }
  Apply-Sprites
})
$window.Add_Closing({
  if ($paused.Count) { Resume-All }
  if ($renderStore.paused.Count) { Resume-AllRenders }
})
$window.Add_Closed({ $timer.Stop(); $pulse.Stop(); $animator.Stop(); $trimEvery.Stop(); $trimTimer.Stop(); Remove-Item -LiteralPath $aliveFile -Force; $mutex.ReleaseMutex() })
[void]$window.ShowDialog()
