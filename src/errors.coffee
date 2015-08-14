Errors = {}

class MessageNotDeliveredError extends Error
  constructor: (messageID) ->
    @name = "MessageNotDeliveredError"
    @message = "message #{messageID} not delivered"
    Error.captureStackTrace(this, MessageNotDeliveredError)

Errors.MessageNotDeliveredError = MessageNotDeliveredError

module.exports = Errors;