Errors = {}

class MessageNotDeliveredError extends Error
  constructor: (messageID, routingKey) ->
    @name = "MessageNotDeliveredError"
    @message = "message #{messageID} not delivered to #{routingKey}"
    Error.captureStackTrace(this, MessageNotDeliveredError)

Errors.MessageNotDeliveredError = MessageNotDeliveredError

module.exports = Errors;