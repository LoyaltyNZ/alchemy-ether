bb = require "bluebird"
_ = require('underscore')

Service = require ('./service')
Bam = require './bam'

SessionClient = require('./session_client')

class Resource

  constructor: (@name, @endpoint, @options = {}) ->

    @session_client = new SessionClient(@options.memcache_uri)

    @service_options = {
      service_queue: true
      ampq_uri: @options.ampq_uri
      timeout: 1000
    }

    @service_options.service_fn = (payload) =>
      #determine method "show, list, create, update, delete"
      method = "create"
      #check if the caller is allowed to call that method
      @check_privilages(payload, method)
      .then( (allowed) =>
        payload.body = JSON.parse(payload.body) if typeof payload.body == 'string'
        return Bam.not_allowed() if !allowed
        
        #log request
        @[method](payload)
        #log response
        #return response
      )
      .catch( (err) -> 
        if err.bam
          return err
        else
          console.log "unhandled Error #{err}"; 
          return Bam.error(err)
      )

    @service = new Service(@endpoint, @service_options)


  create: (context) ->
    Bam.method_not_allowed()

  update: (context) ->
    Bam.method_not_allowed()

  show: (context) ->
    Bam.method_not_allowed()

  list: (context) ->
    Bam.method_not_allowed()

  delete: (context) ->
    Bam.method_not_allowed()

  start: ->
    bb.all([@service.start(), @session_client.connect()])
    .then( =>
      console.log "#{@name} Resource Started with #{JSON.stringify(@service_options)}"
    )


  #### private methods
  check_privilages: (payload, method) ->
    session_id = payload.headers['x-session-id']

    # {"session_id":"","caller_id":"","caller_version":0,"created_at":"","expires_at":"","identity":{"caller_id":"","participant_id":"","outlet_id":""},"scoping":{"authorised_participant_ids":[""],"authorised_programme_codes":[]},"permissions":{"resources":{"PersonAction":{"else":"allow"}},"default":{"else":"deny"}}}
    @session_client.getSession(session_id)
    .then( (session) =>
      bb.all([session, @session_client.getCaller(session.caller_id)])
    )
    .spread((session, caller) =>
      return false if caller.version != session.caller_version

      resource_permissions = session.permissions.resources[@name]
      return false if not resource_permissions


      method_permissions = resource_permissions[method]
      
      if method_permissions
        if method_permissions == 'allow'
          return true 
        else
          return false

      default_resource_permissions = resource_permissions['else']
      if default_resource_permissions
        if default_resource_permissions == 'allow'
          return true
        else
          return false

      return false
    )

module.exports = Resource