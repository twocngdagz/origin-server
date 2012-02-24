require 'active_support/core_ext/hash/conversions'
require 'active_resource'
require 'active_resource/associations'
require 'active_resource/reflection'
require 'active_support/concern'
require 'active_model/dirty'

module ActiveResource
  module Formats
    #
    # The OpenShift REST API wraps the root resource element whi
    # to be unwrapped.
    #
    module OpenshiftJsonFormat
      extend ActiveResource::Formats::JsonFormat
      extend self

      def decode(json)
        decoded = super
        #puts "decoded #{decoded.inspect}"
        if decoded.is_a?(Hash) and decoded.has_key?('data')
          decoded = decoded['data']
        end
        if decoded.is_a?(Array)
          decoded.each { |i| i.delete 'links' }
        else
          decoded.delete 'links'
        end
        decoded
      end
    end
  end
end

module RestApi
  class Base < ActiveResource::Base
    # ActiveResource association support
    extend ActiveResource::Associations
    include ActiveResource::Reflection
    include ActiveModel::Dirty

    def self.debug
      @debug = true
      yield
    ensure
      @debug = false
    end
    def self.debug?
      @debug
    end

    # Exclude the root from JSON
    self.include_root_in_json = false

    #
    # Connection properties
    #
    self.format = :openshift_json
    self.ssl_options = { :verify_mode => OpenSSL::SSL::VERIFY_NONE }
    self.timeout = 60
    self.proxy = 'http://file.rdu.redhat.com:3128'
    self.site = if defined?(Rails) && Rails.configuration.express_api_url
      Rails.configuration.express_api_url + '/broker/rest'
    else
      'http://localhost/broker/rest'
    end

    #
    # ActiveResource doesn't fully support alias_attribute
    #
    class << self
      def alias_attribute(from, to)
        @aliased_attributes ||= {}
        @aliased_attributes[from] = to

        define_method :"#{from}" do
          self.send :"#{to}"
        end
        define_method :"#{from}?" do
          self.send :"#{to}?"
        end
        define_method :"#{from}=" do |val|
          m = method :"#{to}="
          m.call val
        end
      end
      def aliased_attributes
        @aliased_attributes
      end
      def attr_alters(from, *args)
        (@calculated_attributes ||= {})[from] = args.flatten.uniq
        define_attribute_methods [from]
      end
      def calculated_attributes
        @calculated_attributes ||= {}
      end
    end

    def load(attributes)

      if self.class.aliased_attributes
        attributes = attributes.dup
        self.class.aliased_attributes.each do |from,to|
          value = attributes.delete(from)
          send("#{to}=", value) if value
        end
        super attributes
      else
        super
      end
      self.class.calculated_attributes.each_key { |attr| send("#{attr}=", attributes[attr]) }
      self
    end

    # Track persistence state, merged from 
    # https://github.com/railsjedi/rails/commit/9333e0de7d1b8f63b19c99d21f5f65fef0ce38c3
    #
    def initialize(attributes = {}, persisted=false)
      @persisted = persisted
      @as = attributes[:as]
      attributes.delete :as
      super attributes
    end

    # changes to instantiate_record tracked below

    def new?
      !persisted?
    end

    def persisted?
      @persisted
    end

    def load_attributes_from_response(response)
      if response['Content-Length'] != "0" && response.body.strip.size > 0
        load(self.class.format.decode(response.body))
        @persisted = true
        remove_instance_variable(:@update_id) if @update_id
      end
    end

    def save(*args)
      @previously_changed = changes # track changes
      @changed_attributes.clear
      valid = super
      remove_instance_variable(:@update_id) if @update_id && valid
      valid
    rescue Exception => error
      raise error unless rescue_save_failure(error)
      false
    end

    # Copy calculated attribute errors
    def valid?
      if super
        true
      else
        self.class.calculated_attributes.each_pair do |from, attrs|
          attrs.each do |to|
            (errors[from] ||= []).concat(errors[to])
          end
        end
        false
      end
    end

    class << self

      # ActiveResources doesn't completely support ActiveModel::Dirty
      # so implement it for mutable attributes
      def mutable_attribute(name)
        # we need to unset this so that define_attribute_methods
        # doesn't just return
        @attribute_methods_generated = false
        define_attribute_methods [:"#{name}"]
        define_method :"#{name}=" do |val|
          m = method "#{name}_will_change!"
          m.call unless val == @attributes[name]

          @attributes[name] = val
        end
      end

      def custom_id(name, mutable=false)
        @primary_key = name
        @update_id = nil
        if mutable
          # we need to unset this so that define_attribute_methods
          # doesn't just return
          @attribute_methods_generated = false
          define_attribute_methods [:"#{name}"]
          define_method :"#{name}=" do |val|
            m = method "#{name}_will_change!"
            m.call unless val == @attributes[name]
            @update_id = @attributes[name] if @update_id.nil?
            @attributes[name] = val
          end
          define_method :id do
            @update_id || @attributes[name]
          end
        else
          define_method :id do
            @attributes[name]
          end
        end
      end
    end

    #
    # ActiveResource association support
    #
    class << self
      def find_or_create_resource_for_collection(name)
        return reflections[name.to_sym].klass if reflections.key?(name.to_sym)
        find_or_create_resource_for(ActiveSupport::Inflector.singularize(name.to_s))
      end
      private
        def find_or_create_resource_for(name)
          return reflections[name.to_sym].klass if reflections.key?(name.to_sym)
          super
        end
    end

    #
    # singleton support as https://rails.lighthouseapp.com/projects/8994/tickets/4348-supporting-singleton-resources-in-activeresource
    #
    class << self
      def singleton
        @singleton = true
      end
      def singleton?
        @singleton if defined? @singleton
      end

      attr_accessor_with_default(:collection_name) do
        if singleton?
          element_name
        else 
          ActiveSupport::Inflector.pluralize(element_name)
        end
      end

      def element_path(id = nil, prefix_options = {}, query_options = nil) #changed
        prefix_options, query_options = split_options(prefix_options) if query_options.nil?
        #"#{prefix(prefix_options)}#{collection_name}/#{URI.escape id.to_s}.#{format.extension}#{query_string(query_options)}"
        #begin changes
        path = "#{prefix(prefix_options)}#{collection_name}"
        unless singleton?
          raise ArgumentError, 'id is required for non-singleton resources' if id.nil?
          path << "/#{URI.escape id.to_s}"
        end
        path << ".#{format.extension}#{query_string(query_options)}"
      end

      def find(*arguments)

        scope   = arguments.slice!(0)
        options = arguments.slice!(0) || {}

        scope = :one if scope.nil? && singleton? # added

        case scope
        when :all   then find_every(options)
        when :first then find_every(options).first
        when :last  then find_every(options).last
        when :one   then find_one(options)
        else             find_single(scope, options)
        end
      end

      def find_one(options)
        as = options[:as] # for user context support

        case from = options[:from]
        when Symbol
          instantiate_record(get(from, options[:params]))
        when String
          path = "#{from}#{query_string(options[:params])}"
          instantiate_record(format.decode(connection(options).get(path, headers).body), as) #changed
        when nil #begin add
          prefix_options, query_options = split_options(options[:params])
          path = element_path(nil, prefix_options, query_options)
          instantiate_record(format.decode(connection(options).get(path, headers).body), as) #end add
        end
      end
    end


    #
    # has_many / belongs_to placeholders
    #
    #class << self
    #  def has_many(sym)
    #  end
    #  def belongs_to(sym)
    #    prefix = "#{site.path}#{sym.to_s}"
    #  end
    #end

    #
    # Must provide OpenShift compatible error decoding
    #
    def load_remote_errors(remote_errors, save_cache=false)
      case self.class.format
      when ActiveResource::Formats[:openshift_json]
        response = remote_errors.response
        begin
          ActiveSupport::JSON.decode(response.body)['messages'].each do |m|
            self.class.translate_api_error(errors, m['exit_code'], m['field'], m['text'])
          end
        rescue
          msg = if defined? response
            Rails.logger.warn "Unable to read server response, #{response.inspect}"
            Rails.logger.warn "  Body: #{response.body.inspect}" if defined? response.body
            defined?(response.body) ? response.body.to_s : 'No response body from server'
          else
            'No response object'
          end
          raise RestApi::BadServerResponseError, msg, $@
        end
        errors
      else
        super
      end
    end

    class << self
      def translate_api_error(errors, code, field, text)
        message = I18n.t(code, :scope => [:rest_api, :errors], :default => text.to_s)
        errors.add( (field || 'base').to_sym, message) unless message.blank?
      end
    end

    #
    # Override methods from ActiveResource to make them contextual connection
    # aware
    #
    def reload
      self.load(self.class.find(to_param, :params => @prefix_options, :as => as).attributes)
    end

    class << self
      def delete(id, options = {})
        connection(options).delete(element_path(id, options)) #changed
      end

      #
      # Make connection specific to the instance, and aware of user context
      #
      def connection(options = {}, refresh = false)
        if options[:as]
          update_connection(UserAwareConnection.new(site, format, options[:as]))
        else
          raise MissingAuthorizationError
        end
        #elsif defined?(@connection) || superclass == Object
        #  #'Accessing RestApi without a user object'
        #  @connection = update_connection(ActiveResource::Connection.new(site, format)) if @connection.nil? || refresh
        #  @connection
        #else
        #  superclass.connection
        #end
      end

      # possibly needed to decode gets
      #def get(custom_method_name, options = {})
      #  puts 'default get'
      #  self.class.format.decode(connection(options).get(custom_method_collection_url(custom_method_name, options), headers).body) #changed
      #end

      private
        def update_connection(connection)
          connection.proxy = proxy if proxy
          connection.user = user if user
          connection.password = password if password
          connection.auth_type = auth_type if auth_type
          connection.timeout = timeout if timeout
          connection.ssl_options = ssl_options if ssl_options
          connection
        end

        def find_single(scope, options)
          prefix_options, query_options = split_options(options[:params])
          path = element_path(scope, prefix_options, query_options)
          instantiate_record(format.decode(connection(options).get(path, headers).body), options[:as], prefix_options) #changed
        end

        def find_every(options)
          begin
            as = options[:as]
            case from = options[:from]
            when Symbol
              instantiate_collection(get(from, options[:params]), as) #changed
            when String
              path = "#{from}#{query_string(options[:params])}"
              instantiate_collection(format.decode(connection(options).get(path, headers).body) || [], as) #changed
            else
              prefix_options, query_options = split_options(options[:params])
              path = collection_path(prefix_options, query_options)
              instantiate_collection(format.decode(connection(options).get(path, headers).body) || [], as, prefix_options ) #changed
            end
          rescue ActiveResource::ResourceNotFound => e
            # changed to return empty array on not found
            # Swallowing ResourceNotFound exceptions and return nil - as per
            # ActiveRecord.
            [] #changed
          end
        end

        def instantiate_collection(collection, as, prefix_options = {}) #changed
          collection.collect! { |record| instantiate_record(record, as, prefix_options) } #changed
        end

        def instantiate_record(record, as, prefix_options = {}) #changed
          new(record, true).tap do |resource| #changed for persisted flag
            resource.prefix_options = prefix_options
            resource.as = as #added
          end
        end
    end

    def as=(as)
      @connection = nil
      @as = as
    end
    
    protected
      #
      # The user under whose context we will be accessing the remote server
      #
      def as
        return @as
      end

      def connection(refresh = false)
        raise "All RestApi model classes must have the 'as' attribute set in order to make remote requests" unless as
        @connection = nil if refresh
        @connection ||= self.class.connection({:as => as})
      end

      #
      # Return true if the exception has been handled by this method.  Return false
      # to raise.  If returning true, it is expected that errors is populated.
      #
      def rescue_save_failure(error)
        Rails.logger.debug "Unable to handle save error, throwing #{error.inspect}"
        if defined? error.response and defined? error.response.body
          Rails.logger.debug error.response.body
        end
        false
      end

      # Helper to avoid subclasses forgetting to set @remote_errors
      def set_remote_errors(error)
        @remote_errors = error
        load_remote_errors(@remote_errors, true)
      end
  end
  
  #
  # An Authorization object should expose:
  #
  #  login - method returning an identifier for the user
  #
  # and one of:
  #
  #  ticket - the unique ticket for the session
  #  password - a user password
  #
  class Authorization
    attr_reader :login, :ticket, :password
    def initialize(login,ticket=nil,password=nil)
      @login = login
      @ticket = ticket
      @password = password
    end
  end


  #
  # A connection class that contains an authorization object to connect as
  #
  class UserAwareConnection < ActiveResource::Connection

    # The authorization context
    attr :as

    def initialize(url, format, as)
      super url, format
      @as = as
      @user = @as.login if @as.respond_to? :login
      @password = @as.password if @as.respond_to? :password
    end

    def authorization_header(http_method, uri)
      headers = super
      if @as.respond_to? :ticket and @as.ticket
        (headers['Cookie'] ||= '') << "rh_sso=#{@as.ticket}"
      end
      headers
    end

    def new_http
      http = super
      if RestApi::Base.debug?
        http.set_debug_output $stderr
      end
      http
    end

    #
    # Changes made in commit https://github.com/rails/rails/commit/51f1f550dab47c6ec3dcdba7b153258e2a0feb69#activeresource/lib/active_resource/base.rb
    # make GET consistent with other verbs (return response)
    #
    def get(path, headers = {})
      with_auth { request(:get, path, build_request_headers(headers, :get, self.site.merge(path))) } #changed, remove .body at end, removed format decode
    end
  end

  # Raised when the authorization context is missing
  class MissingAuthorizationError < StandardError ; end

  # Raised when a newly created resource exists with the same unique primary key
  class ResourceExistsError < StandardError ; end

  # The server did not return the response we were expecting, possibly a server bug
  class BadServerResponseError < StandardError
  end
end
