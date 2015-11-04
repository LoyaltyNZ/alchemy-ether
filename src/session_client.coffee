bb = require "bluebird"
Memcached = require('memcached')

class SessionClient

  constructor: (@memcache_host = 'localhost:11211', @retries = 2) ->
    @_session_namespace = 'nz_co_loyalty_hoodoo_session_:'
    @_caller_namespace = 'nz_co_loyalty_hoodoo_session_:'

  connected: ->
    !!@_memcached

  connect: () =>
    @_memcached = new Memcached(@memcache_host, { retries: @retries, timeout: 200, remove: true, failures:2 })
    @_memcached = bb.promisifyAll(@_memcached)

    @_memcached.statsAsync()
    .then( (data) =>
      @
    )
    .catch( ->
      throw "Error Connecting to Memcache"
    )

  disconnect: =>
    delete @['_memcached']
    bb.try( -> )

  getSession: (session_id) =>
    @_memcached.getAsync("#{@_session_namespace}#{session_id}")
    .then( (data) ->
      return null unless data?
      try
        return JSON.parse(data)
      catch e
        throw "Session is Corrupt (#{e})"
    )

  getCaller: (caller_id) =>
    @_memcached.getAsync("#{@_caller_namespace}#{caller_id}")
    .then( (data) ->
      return null unless data?
      try
        return JSON.parse(data)
      catch e
        throw "Session is Corrupt (#{e})"
    )

  #THIS IS ONLY USED IN TEST
  setSession: (session_id, body = {}) ->
    @_memcached.setAsync("#{@_session_namespace}#{session_id}", JSON.stringify(body), 10)

module.exports = SessionClient