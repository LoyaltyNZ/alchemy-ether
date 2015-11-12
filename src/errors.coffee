Errors = {}

class MessageNotDeliveredError extends Error
  constructor: (messageID, routingKey) ->
    @name = "MessageNotDeliveredError"
    @message = "message #{messageID} not delivered to #{routingKey}"
    Error.captureStackTrace(this, MessageNotDeliveredError)


# Throwing the NAckError will cause the message to be put back on the queue.
# This is VERY DANGEROUS because if your service can never NAck the message
# it may live forever and cause all sorts of havoc
class NAckError extends Error
  constructor: () ->
    @name = "NAckError"
    @message = "NAck the Message"
    Error.captureStackTrace(this, NAckError)

Errors.NAckError = NAckError
Errors.MessageNotDeliveredError = MessageNotDeliveredError

module.exports = Errors;