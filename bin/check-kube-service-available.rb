#! /usr/bin/env ruby
#
#   check-kube-pods-service-available
#
# DESCRIPTION:
# => Check if your kube services are up and ready
#
# OUTPUT:
#   plain text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#   gem: kube-client
#
# USAGE:
# -s, --api-server URL             URL to API server
# -v, --api-version VERSION        API version. Defaults to 'v1'
#     --in-cluster                 Use service account authentication
#     --ca-file CA-FILE            CA file to verify API server cert
#     --cert CERT-FILE             Client cert to present
#     --key KEY-FILE               Client key for the client cert
# -u, --user USER                  User with access to API
#     --password PASSWORD          If user is passed, also pass a password
#     --token TOKEN                Bearer token for authorization
#     --token-file TOKEN-FILE      File containing bearer token for authorization
# -l, --list SERVICES              List of services to check (required)
# -n NAMESPACES,                   Exclude the specified list of namespaces
#     --exclude-namespace
# -i NAMESPACES,                   Include the specified list of namespaces, an
#     --include-namespace          empty list includes all namespaces
# -p, --pending SECONDS            Time (in seconds) a pod may be pending for and be valid
#
# NOTES:
#
# LICENSE:
#   Barry Martin <nyxcharon@gmail.com>
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'sensu-plugins-kubernetes/cli'
require 'time'

class AllServicesUp < Sensu::Plugins::Kubernetes::CLI
  @options = Sensu::Plugins::Kubernetes::CLI.options.dup

  option :service_list,
         description: 'List of services to check',
         short: '-l SERVICES',
         long: '--list',
         proc: proc { |a| a.split(',') },
         default: ''

  option :pendingTime,
         description: 'Time (in seconds) a pod may be pending for and be valid',
         short: '-p SECONDS',
         long: '--pending',
         default: 0,
         proc: proc(&:to_i)

  option :exclude_namespace,
         description: 'Exclude the specified list of namespaces',
         short: '-n NAMESPACES',
         long: '--exclude-namespace',
         proc: proc { |a| a.split(',') },
         default: ''

  option :include_namespace,
         description: 'Include the specified list of namespaces',
         short: '-i NAMESPACES',
         long: '--include-namespace',
         proc: proc { |a| a.split(',') },
         default: ''

  def run
    services = client.get_services
    failed_services = []
    unchecked_services = []

    unless config[:service_list].nil?
      services.keep_if { |a| config[:service_list].include?(a.metadata.name) }
    end

    unless config[:include_namespace].nil?
      services.keep_if { |a| config[:include_namespace].include?(a.metadata.namespace) }
    end

    unless config[:exclude_namespace].nil?
      services.delete_if { |a| config[:exclude_namespace].include?(a.metadata.namespace) }
    end

    if services.empty?
      warning "No services to check"
    end

    services.each do |a|

      unless services.metadata.name.nil?
        unchecked_services << services.metadata.name
        next
      end

      # Build the selector key so we can fetch the corresponding pod
      selector_key = []
      a.spec.selector.to_h.each do |k, v|
        selector_key << "#{k}=#{v}"
      end
      next if selector_key.empty?

      # Get the pod
      pod = nil
      begin
        pod = client.get_pods(label_selector: selector_key.join(',').to_s)
      rescue
        failed_services << a.metadata.name.to_s
      end
      # Make sure our pod is running
      next if pod.nil?
      pod_available = false
      pod.each do |p|
        case p.status.phase
        when 'Pending'
          next if p.status.startTime.nil?
          if (Time.now - Time.parse(p.status.startTime)).to_i < config[:pendingTime]
            pod_available = true
            break
          end
        when 'Running'
          p.status.conditions.each do |c|
            next unless c.type == 'Ready'
            if c.status == 'True'
              pod_available = true
              break
            end
            break if pod_available
          end
        end
        failed_services << "#{p.metadata.namespace}.#{p.metadata.name}" if pod_available == false
      end
    end

    if failed_services.empty?
      ok 'All services are reporting as up'
    end

    unless failed_services.empty?
      critical "All services are not ready: #{failed_services.join(' ')}"
    end

    unless unchecked_services.empty?
      critical "Some services could not be checked: #{unchecked_services.join(' ')}"
    end

    rescue KubeException => e
    critical 'API error: ' << e.message
   end
end