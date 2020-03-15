#!/usr/bin/env coffee

cfgfile = process.env['RR_CONFIG'] || process.argv[2]

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

fs = require 'fs'

if cfgfile and fs.existsSync cfgfile
  cfg = rmerge cfg, JSON.parse fs.readFileSync(cfgfile)

unless cfg.script?
  console.error "No script configured to execute on job availability"
  process.exit 1

unless fs.existsSync cfg.script
  console.error "Script #{cfg.script} doesn't exist. Can't start"
  process.exit 1



redis = require 'redis'
spawn = require('child_process').spawn


createClient = ()->


class QueueRunner
  constructor: (@queue, worker_count) ->
    @clients = {}
    for i in [0..worker_count-1]
      @clients[i] = new Worker(@queue, i)
      @clients[i].start()

  quit: ()=>
    for i of @clients
      @clients[i].stop()


createRedisClient = ()->
  options = {}
  options.db = cfg.redis.db if cfg.redis.db
  c = redis.createClient cfg.redis.port, cfg.redis.server, options
  c.on "error", (err)->
    console.error "Error: " + err


class Worker
  constructor: (@queue, @id) ->
    @running = false;

  start: ()=>
    @redis = createRedisClient()
    @register()
    @running = true
    @wait_and_process()

  stop: ()=>
    @unregister()
    @running = false;
    @redis.quit()

  wait_and_process: ()=>
    @redis.blpop "resque:queue:#{@queue}", 0, (err, res) =>
      bail = (reason)->
        console.error "Worker-Error: #{reason}"
        process.nextTick(@wait_and_process)

      return bail(err) if err

      job = {}
      try
        job = JSON.parse res[1]
      catch e
        return bail "Parse Error: #{e}"

      @working_on job

      stderr = '';
      stdout = '';
      cat = spawn cfg.script, [@queue]
      cat.stdin.write res[1]
      cat.stdin.end()
      cat.stderr.on 'data', (d) ->
        stderr += d
      cat.stdout.on 'data', (d) ->
        stdout += d
      cat.on 'exit', (code) =>
        if code == 0
          @success()
        else
          @fail job, stderr, stdout

        process.nextTick(@wait_and_process) if @running

  worker_name: =>
    [require('os').hostname(), "#{process.pid}-#{@id}", @queue].join ":"

  register: =>
    name = @worker_name()
    @redis.sadd 'resque:workers', name
    @redis.set "resque:worker:#{name}:started", new Date().toISOString()

  unregister: =>
    name = @worker_name()
    @redis.srem 'resque:workers', name
    @redis.del "resque:worker:#{name}"
    @redis.del "resque:worker:#{name}:started"

  working_on: (data) =>
    data = JSON.stringify
      queue: @queue
      run_at: new Date().toISOString()
      payload: data
    @redis.set "resque:worker:#{@worker_name()}", data

  done: (successful) =>
    name = @worker_name()
    key = if successful then 'processed' else 'failed'
    @redis.incr "resque:stat:#{key}"
    @redis.del "resque:worker:#{name}"

  success: =>
    @done(true)

  fail: (job, stderr, stdout) =>
    @done(false)
    name = @worker_name()
    error =
      failed_at: new Date().toISOString()
      payload: job
      worker: name
      queue: @queue
      backtrace: null

    einfo = {}
    try
      r = JSON.parse stderr
      einfo[k] = r[k] for k in ['exception', 'error', 'backtrace']
    catch e
      einfo =
        exception: 'UnclassifiedRunnerError'
        error: stderr
        stdout: stdout
    @redis.lpush "resque:failed", JSON.stringify(rmerge error, einfo)


queues = {}
clean_exit = ->
  console.log "Exiting cleanly (unregistering workers)"
  for q of queues
    queues[q].quit();
  process.exit 0

exports.run = ->
  for q of cfg.runners
    queues[q] = new QueueRunner(q, cfg.runners[q])

  process.on("SIG#{sig}", clean_exit) for sig in ['INT', 'HUP', 'TERM']
