#!/usr/bin/env coffee

cfgfile = process.argv[2]

cfg =
  redis:
    server: "localhost"
    port: 6379
    db: 2
  runners:
    default: 5

rmerge = (dst, src)->
  for own k, v of src
    dst[k] = v
  dst

if cfgfile and require('path').existsSync cfgfile
  cfg = rmerge cfg, JSON.parse require('fs').readFileSync(cfgfile)

unless cfg.script?
  console.error "No script configured to execute on job availability"
  process.exit 1

unless require('path').existsSync cfg.script
  console.error "Script #{cfg.script} doesn't exist. Can't start"
  process.exit 1

redis = require 'redis'
spawn = require('child_process').spawn

waiters = {}
run_counter = {}

with_redis = (cb) ->
  c = redis.createClient cfg.redis.port, cfg.redis.server
  c.on "connect", ->
    c.select cfg.redis.db, (err, res) ->
        cb(c)
  c.on "error", ->
    c.quit()
    true
  c

new_popper = (queue) ->
  process.nextTick ->
    popper(queue)

class Worker
  constructor: (@queue) ->
    @counter = run_counter[@queue]

  worker_name: ->
    [require('os').hostname(), "#{process.pid}-#{@counter}", @queue].join ":"

  register: ->
    with_redis (redis) =>
      name = @worker_name()
      redis.sadd 'resque:workers', name
      redis.set "resque:worker:#{name}:started", new Date().toISOString()
      redis.quit

  unregister: ->
    with_redis (redis) =>
      name = @worker_name()
      redis.srem 'resque:workers', name
      redis.del "resque:worker:#{name}"
      redis.del "resque:worker:#{name}:started"
      redis.quit

  working_on: (data) ->
    with_redis (redis) =>
      data = JSON.stringify
        queue: @queue
        run_at: new Date().toISOString()
        payload: data
      redis.set "resque:worker:#{@worker_name()}", data
      redis.quit

  done: (redis, successful) ->
    name = @worker_name()
    key = if successful then 'processed' else 'failed'
    redis.incr "resque:stat:#{key}"
    redis.incr "resque:stat:#{key}:#{name}"
    redis.del "resque:worker:#{name}"
    redis.quit

  success: ->
    with_redis (redis) =>
      @done(redis, true)

  fail: (job, response) ->
    with_redis (redis) =>
      @done(redis, false)
      name = @worker_name()
      error =
        failed_at: new Date().toISOString()
        payload: job
        worker: name
        queue: @queue
        backtrace: null

      einfo = {}
      try
        r = JSON.parse response
        einfo[k] = r[k] for k in ['exception', 'error', 'backtrace']
      catch e
        einfo =
          exception: 'UnclassifiedRunnerError'
          error: response
      redis.lpush "resque:failed", JSON.stringify(rmerge error, einfo)
      redis.quit

clean_exit = ->
  with_redis (redis) ->
    console.log "Exiting cleanly (unregistering workers)"
    redis.smembers "resque:workers", (err, workers)->
      return process.exit 1 if err
      re = new RegExp "^#{require('os').hostname()}:#{process.pid}"
      workers = (n for n in workers when re.test n)
      redis.del workers.map (e)-> "resque:worker:#{e}"
      redis.del workers.map (e)-> "resque:worker:#{e}:started"
      redis.del workers.map (e)-> "resque:stat:failed:#{e}"
      redis.srem "resque:workers", workers, (err, res)->
        process.exit 0

popper = (queue) ->
  run_counter[queue] ?= 0
  return if waiters[queue] or run_counter[queue] >= cfg.runners[queue]

  with_redis (redis)->
    waiters[queue] = true
    worker = new Worker(queue)
    worker.register()
    redis.blpop "resque:queue:#{queue}", 0, (err, res) ->
      bail = (reason)->
        console.error "Popper-Error: #{reason}"
        return new_popper queue

      waiters[queue] = false
      return bail(err) if err
      redis.quit()

      job = {}
      try
        job = JSON.parse res[1]
      catch e
        return bail "Parse Error: #{e}"

      worker.working_on job

      run_counter[queue]++
      new_popper queue

      response = '';
      cat = spawn cfg.script, [queue]
      cat.stdin.write res[1]
      cat.stdin.end();
      cat.stderr.on 'data', (d) ->
        response += d
      cat.on 'exit', (code) ->
        run_counter[queue]--
        if code == 0
          worker.success()
        else
          worker.fail job, response
        new_popper queue

popper(q) for q of cfg.runners

process.on("SIG#{sig}", clean_exit) for sig in ['INT', 'HUP', 'TERM']
