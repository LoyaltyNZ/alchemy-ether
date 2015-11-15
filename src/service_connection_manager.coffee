bb = require "bluebird"
amqp = require("amqplib")
_ = require('lodash')

Errors = require './errors'

class ServiceConnectionManager

  log : (message) ->
    console.log "#{(new Date()).toISOString()} - #{@uuid} - #{message}"

  constructor: (@ampq_uri, @uuid, @service_queue_name, @service_handler, @response_queue_name, @response_handler, @returned_handler) ->
    # The states are:
    #                 restarting
    #                  A      |
    #                 error  start()
    #                  |      |
    #     starting ---> started --|
    #        A             |      |
    #      start()        stop()  |
    #        |             V      |
    #     stopped   <-  stopping  |
    #        |                    |
    #        |--------------------|
    #      kill()
    #        |
    #     killing
    #        |
    #        V
    #      dead

    @state = 'stopped'
    @in_flight_messages = {}

  get_connection: ->
    # can only get a connection if starting or started
    throw new Error("#{@uuid}: #get_connection rejected state #{@state}") if !@in_state(['started', 'starting'])

    return @_connection if @_connection
    #@log "creating connection"
    @_connection = amqp.connect(@ampq_uri)
    .then((connection) =>
      #@log "created connection"
      connection.on('error', (error) =>
        @log("AMQP Error connection error - #{error} - #{error.stack || ''}")
        @_connection = null
      )
      connection.on('close', =>
        @_connection = null #connection closed
      )
      connection
    )

  get_service_channel: ->
    #reject if not started, starting, or stopping to reply to messages
    throw new Error("#{@uuid}: #get_service_channel rejected state #{@state}") if !@in_state(['started','starting','stopping'])

    return @_service_channel if @_service_channel

    #@log "creating service channel"

    @_service_channel = @get_connection()
    .then( (connection) =>
      connection.createChannel()
    )
    .then( (service_channel) =>
      #@log "created service channel"
      # http://www.mariuszwojcik.com/2014/05/19/how-to-choose-prefetch-count-value-for-rabbitmq/
      # prefetch will grab a number of un ack'ed messages from the queue
      # since basically the first thing we do is ack a message this number can be quite low
      service_channel.prefetch 20

      service_channel.on('error', (error) =>
        @log "Service Channel Errored #{error}, #{error.stack}"
        @_service_channel = null
      )

      service_channel.on('return', (message) =>
        @log "Message Returned to Channel"
        @returned_handler(message)
      )

      service_channel.on('close', =>
        #@log "Service Channel Closed"
        @_service_channel = null
        if @state == 'started' # i.e. it should be currently running
          @log "AMQP Service Channel closed, restarting service"
          #then restart
          @restart()
        else
          @log "Service Channel stopped"
      )

      @create_response_queue(service_channel)
      .then( => service_channel.assertExchange("resources.exchange", 'topic'))
      .then( => @create_service_queue(service_channel))
      .then( -> service_channel) #return the service channel
    )

  create_response_queue: (service_channel) ->
    if @response_queue_name
      #@log "Creating response queue"
      fn = (msg) =>
        #@log "recieved response message ID `#{JSON.stringify(msg.properties)}`"

        # response immediately acks because no other service is listening to it
        service_channel.ack(msg)
        @response_handler(msg)


      service_channel.assertQueue(@response_queue_name, {expires: 1000})
      .then( (response_queue) =>
        service_channel.consume(@response_queue_name, fn)
      )
    else
      bb.try( -> )

  create_service_queue: (service_channel) ->
    if @service_queue_name
      #@log "Creating service queue"
      fn = (msg) =>
        # @log "recieved service message ID `#{msg.properties.messageId}`"
        #
        # Conditions
        # 1. The Service Function Succeeds
        # 2. The Service Function Has an Unknown Error
        # 3. The Service has a NAckError Error
        # 4. The Service is killed or dies while processing the message

        # 1. will ack the message
        # 2. will log the error then ack the message
        # 3. will log the error then nack the message (so that another service can handle it later)
        # 4. will cause the service channel to die which will not ack the message
        #


        # console.log 'add message', _.keys(@in_flight_messages).length
        @in_flight_messages[msg.properties.messageId] = bb.try( => @service_handler(msg))
        .then( ->
          service_channel.ack(msg)
        )
        .catch( Errors.NAckError, (err) ->
          console.error "NACKed MESSAGE", err.stack
          service_channel.nack(msg)
        )
        .catch( (err) ->
          # If the service has not handled this error, then remove it
          console.error "Service Channel Error", err.stack
          service_channel.ack(msg)
        )
        .finally( =>
          delete @in_flight_messages[msg.properties.messageId]
          #console.log 'remove message', _.keys(@in_flight_messages).length
        )

      service_channel.assertQueue(@service_queue_name, {durable: true})
      .then( =>
        service_channel.consume(@service_queue_name, fn)
      )
      .then( (ret) =>
        @_service_queue_consumer_tag = ret.consumerTag
      )
    else
      bb.try( -> )

  restart: ->
    throw new Error("#{@uuid}: #restart rejected state #{@state}") if !@in_state(['started'])
    @change_state('restarting')
    @start()

  start: ->
    return bb.try( -> true) if @state == 'started'
    # can only start from stopped or restarting
    throw new Error("#{@uuid}: #start rejected state #{@state}") if  !@in_state(['stopped', 'restarting'])
    @change_state('starting')
    try
      @get_service_channel()
      .then( =>
        @change_state('started')
      )
    catch error
      bb.try( -> throw error) # turn actual error into promise error

  stop: ->

    return bb.try( -> true) if @state == 'stopped'
    throw new Error("#{@uuid}: #stop rejected state #{@state}") if !@in_state(['started'])
    bb.all([@get_service_channel(), @get_connection()])
    .spread( (channel, connection) =>
      @change_state('stopping')
      #stop receiving calls
      if @_service_queue_consumer_tag
        stop = channel.cancel(@_service_queue_consumer_tag)
      else
        stop = bb.try(->)

      stop.then( =>
        bb.all(_.values(@in_flight_messages))
      )
      .then( ->
        connection.close()
      )
    )
    .then( =>
      @change_state('stopped')
    )

  in_state: (states) ->
    for s in states
      if @state == s
        return true

    return false

  change_state: (state) ->
    @log "#{@state} -> #{state}"
    @state = state

  kill: ->
    throw new Error("#{@uuid}: #kill rejected state #{@state}") if !@in_state(['stopped','started'])
    @get_connection()
    .then( (connection) =>
      @change_state('killing')
      connection.close()
    )
    .then( =>
      @change_state('dead')
    )


  addResourceToService: (resource_topic) ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.bindQueue(@service_queue_name, "resources.exchange", resource_topic)
    )
    .then( =>
      @log "Bound #{resource_topic} to resources.exchange"
    )

  sendMessageToService: (service, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      options.mandatory = true if options.type == 'http_request'
      service_channel.publish('', service, payload, options)
    )

  sendMessageToResource: (resource, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      options.mandatory = true
      service_channel.publish("resources.exchange", resource, payload, options)
    )

  logMessageToService: (service, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.publish('', service, payload, options)
    )

ServiceConnectionManager.NAckError = Errors.NAckError

module.exports = ServiceConnectionManager
