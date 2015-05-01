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
      #build the context slowly
      context = { 
        resource: @name
      }

      @get_interaction_id(payload)
      .then( (interaction_id) =>
        context.interaction_id = interaction_id
        @get_method(payload)
      )
      .then( (method) =>
        context.method = method
        @get_body(payload)
      )
      .then( (body) =>
        context.body = body
        @get_session(payload)
      )
      .then((session) =>
        context.session = session
        @check_privilages(context)
      )
      .then( (allowed) =>
        throw Bam.not_allowed() if !allowed
        #log request
        log_data = _.clone(context)
        @log_interaction(log_data, 'inbound')
        
        @[context.method](context).then( (resp) =>
          #log response
          log_data = _.clone(context)
          log_data.response = resp
          @log_interaction(log_data, 'outbound')
          resp
        )
      )
      .catch( (err) =>
        if err.bam
          bam_err = err
        else
          bam_err = Bam.error(err)
        console.log "Error #{JSON.stringify(bam_err)}"; 
        

        log_data = _.clone(context)
        log_data.errors = bam_err
        log_data.payload = payload
        log_data.id = bam_err.body.reference
        @log_interaction(log_data, 'outbound', 'error')
        return bam_err
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
      console.log "#{@name} Resource Started with #{JSON.stringify(@options)}"
    )


  #### private methods
  get_body: (payload) ->
    bb.try( ->
      if payload.body
        try
          body = JSON.parse(payload.body) if typeof payload.body == 'string'
          return body
        catch
          throw Bam.malformed_body()
      else
        return {}
    )
    
  get_method: (payload) ->
    bb.try( ->
      switch payload.verb
        when "POST" then method = "create"
        when "PATCH" then method = "update"
        when "DELETE" then method = "delete"
        when "GET" then method = 'show' #TODO later support for list
        else throw Bam.method_not_allowed()
    )

  get_interaction_id: (payload) ->
    bb.try( ->
      interaction_id = payload.headers['x-interaction-id']
      throw Bam.no_interaction_id() if not interaction_id
      interaction_id
    )

  get_session: (payload) ->
    bb.try( =>
      session_id = payload.headers['x-session-id']
      @session_client.getSession(session_id)
    )


  log_interaction: (log_data, code, level = 'info') ->


    data = {
      id: log_data.id || Util.generateUUID()
      created_at: (new Date()).toISOString()
      component: log_data.resource
      code: code
      level: level
      participant_id: log_data?.session?.identity.participant_id #HACK to get scoping working
      interaction_id: log_data?.interaction_id
      data: log_data
    }

    @log_data(data)

  log_data: (data) ->

    options =
      type: 'hoodoo_service_middleware_amqp_log_message'

    @service.sendRawMessage(@logging_queue, data, options)

  check_privilages: (context) ->
    @session_client.getCaller(context.session.caller_id)
    .then( (caller) =>
      not_allowed = false
      allowed = true

      return not_allowed if caller.version != context.session.caller_version

      resource_permissions = context.session.permissions.resources[@name]
      return not_allowed if not resource_permissions


      method_permissions = resource_permissions[context.method]
      
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