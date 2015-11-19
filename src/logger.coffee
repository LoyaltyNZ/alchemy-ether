Util = require("./util")

class Logger

  constructor: (@service, @logging_queue='platform.logging') ->

  log_interaction: (log, code, level = 'info') ->

    data = {
      id:                   log.id || Util.generateUUID()
      interaction_id:       log.interaction_id
      level:                log.level
      component:            log.resource
      code:                 log.code
      reported_at:          (new Date()).toISOString()
      data:                 log
      caller_identity_name: log.caller_identity_name
      caller_id:            log.caller_id
      resource:             log.resource
      action:               log.action
    }

    @log_data(data)

  log_data: (data) ->
    @service.logMessageToService(@logging_queue, data)


module.exports = Logger