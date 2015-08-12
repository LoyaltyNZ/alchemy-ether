class Resource
  constructor: (@name) ->

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

module.exports = Resource