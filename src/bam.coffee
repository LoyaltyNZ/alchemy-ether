#error handling like Boom but Bam
Util = require "./util"
Bam = {}

Bam.method_not_allowed = ->
  {
    code: "platform.method_not_allowed"
    message: "not allowed"
    reference: Util.generateUUID()
    status: 405
  }


module.exports = Bam