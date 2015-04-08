bb = require "bluebird"
_ = require('underscore')

Service = require ('./service')
Bam = require './bam'

SessionClient = require('./session_client')
Util = require("./util")

class Resource

  constructor: (@name, @endpoint, @options = {}) ->

    @session_client = new SessionClient(@options.memcache_uri)
    
    @logging_queue = process.env['AMQ_LOGGING_ENDPOINT'] || 'platform.logging'

    @service_options = {
      service_queue: true
      ampq_uri: @options.ampq_uri
      timeout: 1000
    }

    @service_options.service_fn = (payload) =>
      interaction_id = payload.headers['x-interaction-id']

      #determine method "show, list, create, update, delete"
      method = "create"
      #check if the caller is allowed to call that method
      @check_privilages(payload, method)
      .spread( (allowed, session) =>
        payload.body = JSON.parse(payload.body) if typeof payload.body == 'string'
        throw Bam.not_allowed() if !allowed
        
        #log request
        @log_interaction(interaction_id, 'inbound', method, payload, session)

        @[method](payload).then( (resp) =>
          #log response
          @log_interaction(interaction_id, 'outbound', method, resp, session)
          resp
        )
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

  log_interaction: (interaction_id, direction, method, payload, session) ->
    data = {
      id: Util.generateUUID()
      component: 'Middleware'
      level: 'info'
      participant_id: session.identity.participant_id #HACK to get scoping working
      interaction_id: interaction_id
      code: direction
      data:
        interaction_id: interaction_id
        resource: @name
        payload: payload
        session: session
        method: method
    }

    @log_data(data)

  log_data: (data) ->

    options =
      type: 'hoodoo_service_middleware_amqp_log_message'

    @service.sendRawMessage(@logging_queue, data, options)

  check_privilages: (payload, method) ->
    session_id = payload.headers['x-session-id']

    # {"session_id":"","caller_id":"","caller_version":0,"created_at":"","expires_at":"","identity":{"caller_id":"","participant_id":"","outlet_id":""},"scoping":{"authorised_participant_ids":[""],"authorised_programme_codes":[]},"permissions":{"resources":{"PersonAction":{"else":"allow"}},"default":{"else":"deny"}}}
    @session_client.getSession(session_id)
    .then( (session) =>
      bb.all([session, @session_client.getCaller(session.caller_id)])
    )
    .spread((session, caller) =>
      not_allowed = [false,session]
      allowed = [true, session]
      return not_allowed if caller.version != session.caller_version

      resource_permissions = session.permissions.resources[@name]
      return not_allowed if not resource_permissions


      method_permissions = resource_permissions[method]
      
      if method_permissions
        if method_permissions == 'allow'
          return allowed 
        else
          return not_allowed

      default_resource_permissions = resource_permissions['else']
      if default_resource_permissions
        if default_resource_permissions == 'allow'
          return allowed
        else
          return not_allowed

      return not_allowed
    )

module.exports = Resource