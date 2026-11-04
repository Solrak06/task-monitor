import type { EngineInterface, Register } from 'claude-code'

// The session's state is written straight to ~/.claude/task-monitor/sessions/<id>.json from here.
// app/launch.ps1 (a PowerShell process) only runs when it has work: finding the session's
// claude.exe pid once, or opening the monitor window when it is not already running.

type State = 'busy' | 'waiting' | 'idle' | 'error' | 'ended'

type Record = {
  session: string
  state: State
  cwd: string
  root: string
  prompt: string
  since: number
  updated: number
  firstSeen: number
  tasks: number
  workMs: number
  lastMs: number
  model: string
  context: number
  contextPct: number
  output: number
  agents: number
  waitingFor: string
  error: string
  opened: boolean
}

const records = new Map<string, Record>()
const pidKnown = new Set<string>()

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'monitor', description: 'Abre el monitor de tareas (CPU/RAM)' })
    const usage = await $.session.usage().catch(() => undefined)
    if (usage?.rateLimits.length) await writeUsage($, usage.rateLimits)

    return next(e)
  })

  on('command.run', { command: 'monitor' }, async $ => {
    await $.process.run(launcher($.plugin.root, { Session: await $.session.id(), State: 'open' })).catch(() => undefined)

    return { text: 'Monitor de tareas abierto.' }
  })

  on('prompt.submit', async ($, e, next) => {
    if (!e.command) {
      // Prompts the engine raises itself (task notifications and the like) keep the last typed one
      const isTyped = !e.isMeta && !e.text.trimStart().startsWith('<')
      const prompt = e.text.replace(/\s+/g, ' ').replace(/^[-\s]+/, '').slice(0, 160)
      const r = await load($)
      if (isTyped) r.prompt = prompt || '(sin texto)'
      r.cwd = await $.session.cwd()
      r.root = await $.session.root().catch(() => r.root)
      r.agents = 0
      setState(r, 'busy')
      await save($, r)
      void maybeLaunch($, r)
    }

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const r = await load($)
      const usage = e.usage
      if (usage) {
        r.model = usage.model || r.model
        r.context = usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens || r.context
        r.output = usage.output_tokens ?? 0
      }
      if (r.state === 'busy' || r.state === 'waiting') {
        r.lastMs = e.durationMs || Date.now() - r.since
        r.tasks += 1
        r.workMs += r.lastMs
      }
      r.agents = 0
      r.waitingFor = ''
      r.error = e.reason === 'error' ? 'la respuesta terminó con un error' : ''
      setState(r, e.reason === 'error' ? 'error' : 'idle')
      await save($, r)
    }

    return next(e)
  })

  // A permission prompt or a question the model put to the person: the session waits on them
  on('classic.Notification', async ($, e, next) => {
    if (e.notification_type === 'permission_prompt' || e.notification_type === 'elicitation_dialog') {
      const r = await load($)
      if (r.state === 'busy') {
        r.waitingFor = e.notification_type === 'permission_prompt' ? 'permiso' : 'respuesta'
        setState(r, 'waiting')
        await save($, r)
      }
    }

    return next(e)
  })

  on('classic.PostToolUse', async ($, e, next) => (await resumeWork($), next(e)))
  on('classic.PostToolUseFailure', async ($, e, next) => (await resumeWork($), next(e)))
  on('classic.PermissionDenied', async ($, e, next) => (await resumeWork($), next(e)))
  on('classic.ElicitationResult', async ($, e, next) => (await resumeWork($), next(e)))

  on('classic.SubagentStart', async ($, e, next) => {
    const r = await load($)
    r.agents += 1
    await save($, r)

    return next(e)
  })
  on('classic.SubagentStop', async ($, e, next) => {
    const r = await load($)
    r.agents = Math.max(0, r.agents - 1)
    await save($, r)

    return next(e)
  })

  on('classic.StopFailure', async ($, e, next) => {
    const r = await load($)
    r.error = e.error
    setState(r, 'error')
    await save($, r)

    return next(e)
  })

  on('classic.CwdChanged', async ($, e, next) => {
    const r = await load($)
    r.cwd = e.new_cwd
    await save($, r)

    return next(e)
  })

  // Context fill and the account's rate-limit windows (the weekly one among them)
  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('rateLimits') && e.rateLimits.length) await writeUsage($, e.rateLimits)
    if (e.changed.includes('context') && e.context.percent !== undefined) {
      const r = await load($)
      r.contextPct = e.context.percent
      if (e.context.tokens) r.context = e.context.tokens
      await save($, r)
    }

    return next(e)
  })

  on('session.end', async ($, e, next) => {
    const r = records.get(e.sessionId)
    if (r) {
      r.state = 'ended'
      r.updated = Date.now()
      await $.fs.write(`${await dataDir($)}/sessions/${r.session}.json`, JSON.stringify(r)).catch(() => undefined)
    } else {
      void $.process.run(launcher($.plugin.root, { Session: e.sessionId, State: 'ended' })).catch(() => undefined)
    }

    return next(e)
  })
}

type Ctx = EngineInterface

let home: string | undefined
async function dataDir($: Ctx) {
  home ??= (await $.env.get('USERPROFILE')) ?? ''

  return `${home.replace(/\\/g, '/')}/.claude/task-monitor`
}

async function load($: Ctx): Promise<Record> {
  const id = await $.session.id()
  const known = records.get(id)
  if (known) return known
  const now = Date.now()
  const fresh: Record = {
    session: id, state: 'idle', cwd: '', root: '', prompt: '', since: now, updated: now, firstSeen: now,
    tasks: 0, workMs: 0, lastMs: 0, model: '', context: 0, contextPct: 0, output: 0, agents: 0, waitingFor: '', error: '', opened: false,
  }
  // A reloaded module or a resumed session goes on from what the file holds
  const text = await $.fs.read(`${await dataDir($)}/sessions/${id}.json`).catch(() => undefined)
  if (typeof text === 'string') {
    try {
      const old = JSON.parse(text.replace(/^﻿/, '')) as Partial<Record> & { pid?: number }
      Object.assign(fresh, Object.fromEntries(Object.entries(old).filter(([k]) => k in fresh)))
      if (old.pid) pidKnown.add(id)
    } catch {}
  }
  records.set(id, fresh)

  return fresh
}

// After the person answered: a tool ran, was refused, or the question got its answer
async function resumeWork($: Ctx) {
  const r = await load($)
  if (r.state === 'waiting') {
    r.waitingFor = ''
    setState(r, 'busy')
    await save($, r)
  }
}

function setState(r: Record, state: State) {
  if (r.state !== state) r.since = Date.now()
  r.state = state
}

async function save($: Ctx, r: Record) {
  r.updated = Date.now()
  await $.fs.write(`${await dataDir($)}/sessions/${r.session}.json`, JSON.stringify(r)).catch(() => undefined)
}

async function writeUsage($: Ctx, limits: readonly { kind: string; percentUsed: number; resetsAt?: string }[]) {
  const body = { updated: Date.now(), limits: limits.map(l => ({ kind: l.kind, percent: l.percentUsed, resetsAt: l.resetsAt ?? '' })) }
  await $.fs.write(`${await dataDir($)}/usage.json`, JSON.stringify(body)).catch(() => undefined)
}

// PowerShell starts only when the pid is still unknown or the window is not running (its heartbeat is old)
async function maybeLaunch($: Ctx, r: Record) {
  const dir = await dataDir($)
  if (!pidKnown.has(r.session)) {
    const pidFile = await $.fs.stat(`${dir}/sessions/${r.session}.pid`).catch(() => undefined)
    if (pidFile) pidKnown.add(r.session)
  }
  const beat = await $.fs.stat(`${dir}/alive`).catch(() => undefined)
  const isRunning = beat !== undefined && Date.now() - beat.mtimeMs < 15000
  if (pidKnown.has(r.session) && isRunning) return
  const isFirst = !r.opened
  r.opened = true
  await $.process.run(launcher($.plugin.root, { Session: r.session, State: 'busy', First: isFirst ? '1' : '0' })).catch(() => undefined)
}

function launcher(root: string, args: { [name: string]: string }) {
  return [
    'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', `${root}/app/launch.ps1`,
    ...Object.entries(args).flatMap(([name, value]) => [`-${name}`, value]),
  ]
}
