class TriggerWorkflowController < TriggerController
  include ScmWebhookHeadersDataExtractor
  include ScmWebhookPayloadDataExtractor

  # We don't need to validate that the body of the request is XML. We receive JSON
  skip_before_action :validate_xml_request, :set_project_name, :set_package_name, :set_project, :set_package, :set_object_to_authorize, :set_multibuild_flavor

  before_action :set_scm_event
  before_action :set_scm_extractor
  before_action :extract_scm_webhook
  before_action :verify_event_and_action
  before_action :create_workflow_run
  before_action :validate_scm_event

  def create
    authorize @token, :trigger?
    @token.executor.run_as do
      validation_errors = @token.call(workflow_run: @workflow_run, scm_webhook: @scm_webhook)

      unless @workflow_run.status == 'fail' # The SCMStatusReporter might already set the status to 'fail', lets not overwrite it
        if validation_errors.none?
          @workflow_run.update(status: 'success', response_body: render_ok)
        else
          @workflow_run.update_as_failed(render_error(status: 400, message: validation_errors.to_sentence))
        end
      end
    # We always want to return 200 in the request. Because a lot of things in `Workflow`` can go wrong outside this request cycle.
    # People need to have a look at their `WorkflowRun` to see how `Workflow` went.
    rescue APIError => e
      @workflow_run.update_as_failed(render_error(status: e.status, errorcode: e.errorcode, message: e.message))
    rescue Pundit::NotAuthorizedError => e
      @workflow_run.update_as_failed(e.message)
    end
  end

  private

  def set_scm_extractor
    @scm_extractor = TriggerControllerService::SCMExtractor.new(scm_vendor, hook_event, payload)
  end

  def extract_scm_webhook
    @scm_webhook = @scm_extractor.call
    return @scm_webhook if @scm_webhook && @scm_extractor.valid?

    raise Trigger::Errors::MissingExtractor, @scm_extractor.error_message
  end

  def create_workflow_run
    raise Trigger::Errors::InvalidToken, 'Wrong token type. Please use workflow tokens only.' unless @token.is_a?(Token::Workflow)

    request_headers = request.headers.to_h.keys.map { |k| "#{k}: #{request.headers[k]}" if k.match?(/^HTTP_/) }.compact.join("\n")
    @workflow_run = @token.workflow_runs.create(request_headers: request_headers,
                                                request_payload: request.body.read,
                                                workflow_configuration_path: @token.workflow_configuration_path,
                                                workflow_configuration_url: @token.workflow_configuration_url,
                                                scm_vendor: scm_vendor,
                                                hook_event: hook_event,
                                                hook_action: extract_hook_action,
                                                repository_name: extract_repository_name,
                                                repository_owner: extract_repository_owner,
                                                event_source_name: extract_event_source_name,
                                                generic_event_type: extract_generic_event_type)
  end

  def verify_event_and_action
    # There are plenty of different pull/merge request and push events which we don't support.
    # Those should not cause an error, we simply ignore them.
    return unless @scm_webhook.ignored_pull_request_action? || @scm_webhook.ignored_push_event? || ignored_event?

    action = @scm_webhook.payload[:action]

    info_msg = "Events '#{@scm_webhook.payload[:event]}' "
    info_msg += "and actions '#{action}' " if action.present?
    info_msg += 'are unsupported'

    render_ok(data: { info: info_msg })
  end

  def validate_scm_event
    return if @scm_extractor.valid?

    @workflow_run.update_as_failed(
      render_error(
        status: 400,
        errorcode: 'bad_request',
        message: @scm_extractor.error_message
      )
    )
  end
end
