#error handling like Boom but Bam
Util = require "./util"
Bam = {}

Bam.joi_validation_error = (joi_error) ->
  errors = [] 
  for deet in joi_error.details
    switch deet.type 
      when 'any.required'
        errors.push {
          code: "generic.required_field_missing"
          message: deet.message
        }
      when 'object.missing'
        errors.push {
          code: "generic.required_field_missing"
          message: deet.message
        }
      when 'string.regex.base'
        errors.push {
          code: "generic.invalid_string"
          message: deet.message
        }
      else
        errors.push {
          code: "generic.unknown"
          message: deet.message
          type: deet.type
        }

  {
    bam: true
    status_code: 422
    body: {
      errors: errors
      reference: Util.generateUUID()
    }
  }

Bam.malformed_body = ->
  {
    bam: true
    status_code: 422
    body: {
      code: "platform.malformed"
      message: "malformed body data"
      reference: Util.generateUUID()
    }
  }

Bam.method_not_allowed = ->
  {
    bam: true
    status_code: 405
    body: {
      code: "platform.method_not_allowed"
      message: "not allowed"
      reference: Util.generateUUID()
    }
  }

Bam.no_interaction_id = ->
  {
    bam: true
    status_code: 422
    body: {
      code: "platform.no_interaction_id"
      message: "no interaction id"
      reference: Util.generateUUID()
    }
  }

Bam.required_field_missing = (message) ->
  {
    bam: true
    status_code: 422
    body: {
      code: "generic.required_field_missing"
      message: "#{message}"
      reference: Util.generateUUID()
    }
  }

Bam.not_allowed = ->
  {
    bam: true
    status_code: 403
    body: {
      code: "platform.forbidden"
      message: "not allowed"
      reference: Util.generateUUID()
    }
  } 

Bam.not_found = (resource) ->
  {
    bam: true
    status_code: 404
    body: {
      code: "platform.not_found"
      message: "#{resource} not found"
      reference: Util.generateUUID()
    }
  } 

Bam.exists = (resource) ->
  {
    bam: true
    status_code: 422
    body: {
      code: "platform.exists"
      message: "#{resource} already exists"
      reference: Util.generateUUID()
    }
  } 

Bam.error = (err) ->
  error = {
    bam: true
    status_code: 500
    body: {
      code: 'platform.fault'
      message: 'An unexpected error occurred'
      
    }
  }

  if process.env.NODE_ENV in ['development', 'test', 'staging']
    error.stack = err.stack
  error

module.exports = Bam