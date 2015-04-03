#error handling like Boom but Bam
Util = require "./util"
Bam = {}

Bam.method_not_allowed = ->
  {
    status_code: 405
    body: {
      code: "platform.method_not_allowed"
      message: "not allowed"
      reference: Util.generateUUID()
    }
  }

Bam.not_allowed = ->
  {
    status_code: 403
    body: {
      code: "platform.forbidden"
      message: "not allowed"
      reference: Util.generateUUID()
    }
  } 

Bam.error = (err) ->
  {
    status_code: 500
    body: {
      code: 'platform.fault'
      message: 'An unexpected error occurred'
      stack: err
    }
  }
  
module.exports = Bam