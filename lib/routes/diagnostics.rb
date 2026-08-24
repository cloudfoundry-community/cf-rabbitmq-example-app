helpers do
  # Per-protocol availability report: whether the binding advertises it,
  # whether it can be derived, and the endpoint (and URL path) that would
  # be used. Shared by /protocols and the root index so the two views
  # can't drift apart on what "available", "derived" or "unavailable"
  # means. The endpoint object itself is included for callers that need
  # it - render its #to_h, never the endpoint, to keep the password out.
  def protocol_report
    RabbitMQ::Resolver::PROTOCOLS.map do |name|
      endpoint = resolver.resolve(name)
      {
        'name' => name,
        'path' => "/#{name.tr('_', '-')}",
        'endpoint' => endpoint,
        'available' => !endpoint.nil?,
        'source' => endpoint&.source,
        'reason' => endpoint ? nil : resolver.unavailable_reason(name),
        'adapter' => !RabbitMQ::Registry.adapter_for(name).nil?
      }
    end
  end
end

# Reports, per protocol, whether the binding advertises it, whether it can
# be derived, and the endpoint (and URL path) that would be used.
# Passwords are never included. This is what makes forge issue #96
# observable from the app instead of a mystery when a mode misbehaves.
get '/protocols' do
  report = protocol_report.each_with_object({}) do |entry, acc|
    acc[entry['name']] =
      if entry['available']
        entry['endpoint'].to_h.merge(
          'available' => true,
          'adapter' => entry['adapter'] ? 'yes' : 'none',
          'path' => entry['path']
        )
      else
        { 'available' => false, 'reason' => entry['reason'], 'path' => entry['path'] }
      end
  end

  content_type :json
  status 200
  body JSON.pretty_generate(report)
end
