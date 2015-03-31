uuid = require 'node-uuid'
class Util

  @generateUUID: ->
    uuid.v4().replace(/-/g,'')

module.exports = Util