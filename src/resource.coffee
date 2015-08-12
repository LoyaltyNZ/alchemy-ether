bb = require "bluebird"
_ = require('lodash')

Service = require ('./service')
Bam = require './bam'

SessionClient = require('./session_client')
Util = require("./util")
Logger = require("./logger")

class Resource

  constructor: (@name, @endpoint, @options = {}) ->

    if !@endpoint
      @endpoint = @name

    @session_client = new SessionClient(@options.memcache_uri)
    
    @options = _.defaults(
      @options,
      {
        logging_endpoint: 'platform.logging'
      }
    )

    

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
        @get_query(payload)
      )
      .then( (query) =>
        context.path = query.path
        context.query = query.query
        @get_session(payload)
      )
      .then((session) =>
        context.session = session
        @check_privilages(context)
      )
      .then( (allowed) =>
        throw Bam.not_allowed() if !allowed
        #log request
        log_data = _.cloneDeep(context)
        @logger.log_interaction(log_data, 'inbound')
        st = new Date().getTime()
        bb.try( => @[context.method](_.cloneDeep(context)))
        .then( (resp) =>
          #log response
          log_data.response = resp

          et = new Date().getTime()
          log_data.response_time = et - st
          @logger.log_interaction(log_data, 'outbound')

          resp
        )
        .catch( (err) =>
          #service error
          if err.bam
            bam_err = err
          else
            bam_err = Bam.error(err)
          console.log "Service Error #{JSON.stringify(bam_err)}"; 
          log_data.errors = bam_err
          log_data.id = bam_err.body.reference
          @logger.log_interaction(log_data, 'outbound', 'error')
          return bam_err
        )
      )
      .catch( (err) =>
        #platform Error
        if err.bam
          bam_err = err
        else
          bam_err = Bam.error(err)
        console.log "Platform Error #{JSON.stringify(bam_err)}"; 

        log_data = _.clone(context)
        log_data.errors = bam_err
        log_data.payload = payload
        log_data.id = bam_err.body.reference
        @logger.log_interaction(log_data, 'outbound', 'error')
        return bam_err
      )

    @service = new Service(@endpoint, @service_options)
    @logger = new Logger(@service, @options.logging_endpoint )

  create: (context) ->
    throw Bam.method_not_allowed()

  update: (context) ->
    throw Bam.method_not_allowed()

  show: (context) ->
    throw Bam.method_not_allowed()

  list: (context) ->
    throw Bam.method_not_allowed()

  delete: (context) ->
    throw Bam.method_not_allowed()

  start: ->
    bb.all([@service.start(), @session_client.connect()])
    .then( =>
      console.log "#{@name} Resource Started with #{JSON.stringify(@options)}"
    )

  stop: ->
    bb.all([@service.stop(), @session_client.disconnect()])
    .then( =>
      console.log "#{@name} Resource Stopped"
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

  get_query: (payload) ->
    {
      path: payload.path
      query: payload.query
    }


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





  check_privilages: (context) ->
    return bb.try(-> false) if !context || !context.session || !context.session.caller_id
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