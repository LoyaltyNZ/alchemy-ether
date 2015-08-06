Util = require("./util")

class Logger

  constructor: (@service, @logging_queue='platform.logging') ->
  
  log_interaction: (log_data, code, level = 'info') ->
    data = {
      id: log_data.id || Util.generateUUID()
      created_at: (new Date()).toISOString()
      component: log_data.resource
      code: code
      level: level
      participant_id: log_data?.session?.identity.participant_id #HACK to get scoping working
      interaction_id: log_data?.interaction_id
      data: log_data
    }
    @log_data(data)

  log_data: (data) ->

    options =
      type: 'logging_event'
  
    @service.sendRawMessage(@logging_queue, data, options)


module.exports = Logger