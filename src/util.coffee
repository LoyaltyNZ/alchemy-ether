uuid = require 'node-uuid'
class Util

  @generateUUID: ->
    uuid.v4().replace(/-/g,'')

  @pathToTopic: (path) ->
    new_path = ""
    depth_counter = 1
    for c,i in path
      if c == '/'
        new_path += '.' if i != 0 and i != path.length-1
        #new_path += depth_counter
        depth_counter += 1
      else
        new_path += c

    new_path

module.exports = Util