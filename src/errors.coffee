Errors = {}

# Throwing the NAckError will cause the message to be put back on the queue.
# This is VERY DANGEROUS because if your service can never NAck the message
# it may live forever and cause all sorts of havoc
class NAckError extends Error
  constructor: () ->
    @name = "NAckError"
    @message = "NAck the Message"
    Error.captureStackTrace(this, NAckError)

Errors.NAckError = NAckError

module.exports = Errors;