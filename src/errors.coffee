Errors = {}

class NAckError extends Error
  constructor: () ->
    @name = "NAckError"
    @message = "NAck the Message"
    Error.captureStackTrace(this, NAckError)

Errors.NAckError = NAckError

module.exports = Errors;