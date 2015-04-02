bb = require "bluebird"
_ = require('underscore')

Service = require ('./service')
Bam = require './bam'

class Resource

  constructor: () ->
    options = {}
    options.service_fn = (payload) =>
      #check_security
      #check_path
      #create context
      #log payload logging async
      #call resource method
      #log response async
      #return response
      @create(payload)

    @service = new Service(@name, options)


  create: (context) ->
    Bam.method_not_allowed()

  start: ->
    @service.start()

module.exports = Resource