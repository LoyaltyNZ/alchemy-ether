bb = require "bluebird"
_ = require('lodash')

Util = require("./util")
Bam = require './bam'

class Resource
  constructor: (@name, @path) ->
    @_base_topic = Util.pathToTopic(@path)
    @topic = "#{@_base_topic}.#"

  start: () ->
    bb.try( -> )

  stop: () ->
    bb.try( -> )

  create: (context) ->
    throw Bam.method_not_allowed()

  update: (context) ->
    throw Bam.method_not_allowed()

  show: (context) ->
    throw Bam.method_not_allowed()

  delete: (context) ->
    throw Bam.method_not_allowed()

  matches_topic: (try_topic) ->
    ret = _.startsWith(try_topic, @_base_topic)
    return ret

module.exports = Resource