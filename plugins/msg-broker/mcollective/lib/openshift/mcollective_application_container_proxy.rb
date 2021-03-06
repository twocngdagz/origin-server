require 'mcollective'
require 'open-uri'

include MCollective::RPC

#
# The OpenShift module is a namespace for all OpenShift related objects and
# methods.
#
module OpenShift

    # Implements the broker-node communications This class the state
    # of a node and a set of RPC functions to the node.  It also has a
    # set of just plain functions which live here because they relate
    # to broker/node communications.
    #
    class MCollectiveApplicationContainerProxy < OpenShift::ApplicationContainerProxy

      # the "cartridge" for Node operation messages to "cartridge_do"
      @@C_CONTROLLER = 'openshift-origin-node'

      # A Node ID string
      attr_accessor :id

      # A District ID string
      attr_accessor :district

      # <<constructor>>
      #
      # Create an app descriptor/handle for remote controls
      #
      # INPUTS:
      # * id: string - a unique app identifier
      # * district: <type> - a classifier for app placement
      #
      def initialize(id, district=nil)
        @id = id
        @district = district
      end
      
      # <<class method>>
      #
      # Determine what gear sizes are valid for a given user
      #
      # INPUT:
      # * user: a reference to a user object
      #
      # RETURN:
      # * list of strings: names of gear sizes
      #
      # NOTE:
      # * an operation on User?
      # * Uses only operations and attributes of user
      #
      def self.valid_gear_sizes_impl(user)
        user_capabilities = user.get_capabilities
        capability_gear_sizes = []
        capability_gear_sizes = user_capabilities['gear_sizes'] if user_capabilities.has_key?('gear_sizes')

        if user.auth_method == :broker_auth
          return ["small", "medium"] | capability_gear_sizes
        elsif !capability_gear_sizes.nil? and !capability_gear_sizes.empty?
          return capability_gear_sizes
        else
          return ["small"]
        end
      end
      
      # <<factory method>>
      #
      # Find a node which fulfills app requirements.  Implements the superclass
      # find_available() method
      #
      # INPUTS:
      # * node_profile: string identifier for a set of node characteristics
      # * district_uuid: identifier for the district
      # * least_preferred_server_identities: list of server identities that are least preferred. These could be the ones that won't allow the gear group to be highly available
      # * gear_exists_in_district: true if the gear belongs to a node in the same district  
      # * required_uid: the uid that is required to be available in the destination district
      #
      # RETURNS:
      # * an MCollectiveApplicationContainerProxy
      #
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES:
      # * a class method on Node?
      # * Uses Rails.configuration.msg_broker
      # * Uses District
      # * Calls rpc_find_available
      # 
      # VALIDATIONS:
      # * If gear_exists_in_district is true, then required_uid cannot be set and has to be nil
      # * If gear_exists_in_district is true, then district_uuid must be passed and cannot be nil
      #
      def self.find_available_impl(node_profile=nil, district_uuid=nil, least_preferred_server_identities=nil, gear_exists_in_district=false, required_uid=nil)
        district = nil
        current_server, current_capacity, preferred_district = rpc_find_available(node_profile, district_uuid, least_preferred_server_identities, false, gear_exists_in_district, required_uid)
        if !current_server
          current_server, current_capacity, preferred_district = rpc_find_available(node_profile, district_uuid, least_preferred_server_identities, true, gear_exists_in_district, required_uid)
        end
        district = preferred_district if preferred_district
        raise OpenShift::NodeException.new("No nodes available.", 140) unless current_server
        Rails.logger.debug "DEBUG: find_available_impl: current_server: #{current_server}: #{current_capacity}"

        MCollectiveApplicationContainerProxy.new(current_server, district)
      end
      
      # <<factory method>>
      #
      # Find a single node. Implements superclass find_one() method. 
      # 
      # INPUTS:
      # * node_profile: characteristics for node filtering
      #
      # RETURNS:
      # * MCollectiveApplicationContainerProxy
      #
      # NOTES:
      # * Uses rpc_find_one() method
      
      def self.find_one_impl(node_profile=nil)
        current_server = rpc_find_one(node_profile)
        current_server, capacity, district = rpc_find_available(node_profile) unless current_server 
        
        raise OpenShift::NodeException.new("No nodes found.", 140) unless current_server
        Rails.logger.debug "DEBUG: find_one_impl: current_server: #{current_server}"

        MCollectiveApplicationContainerProxy.new(current_server)
      end

      # <<orphan>>
      # <<class method>>
      #
      # Return a list of blacklisted namespaces and app names.
      # Implements superclass get_blacklisted() method.
      # 
      # INPUTS:
      # * none
      # 
      # RETURNS:
      # * empty list
      #
      # NOTES:
      # * Is this really a function of the broker
      #
      def self.get_blacklisted_in_impl
        []
      end

      # <<orphan>>
      #
      # <<class method>>
      #
      # INPUTS:
      # * name: String.  A name to be checked against the blacklist
      #
      # RETURNS:
      # * Boolean.  True if the name is in the blacklist
      #
      # NOTES:
      # * This is really a function of the broker
      #
      def self.blacklisted_in_impl?(name)
        false
      end
      

      # <<class method>>
      #
      # <<query>>
      #
      # Query all nodes for all available cartridges
      #
      # INPUTS:
      # * none
      #
      # RETURNS:
      # * An array of OpenShift::Cartridge objects
      #
      # NOTES:
      # * uses execute_direct and @@C_CONTROLLER
      #
      def get_available_cartridges
        args = Hash.new
        args['--porcelain'] = true
        args['--with-descriptors'] = true
        result = execute_direct(@@C_CONTROLLER, 'cartridge-list', args, false)
        result = parse_result(result)
        cart_data = JSON.parse(result.resultIO.string)
        cart_data.map! {|c| OpenShift::Cartridge.new.from_descriptor(YAML.load(c))}
      end

      # <<object method>>
      #
      # <<attribute getter>>
      #
      # Request the disk quotas from a Gear on a node
      #
      # RETURNS:
      # * an array with following information:
      #
      # [Filesystem, blocks_used, blocks_soft_limit, blocks_hard_limit, 
      # inodes_used, inodes_soft_limit, inodes_hard_limit]
      #
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES
      # * Uses execute_direct
      # * A method on the gear object
      #
      def get_quota(gear)
        args = Hash.new
        args['--uuid'] = gear.uuid
        reply = execute_direct(@@C_CONTROLLER, 'get-quota', args, false)

        output = nil
        exitcode = 0
        if reply and reply.length > 0
          mcoll_result = reply[0]
          if (mcoll_result && (defined? mcoll_result.results) && !mcoll_result.results[:data].nil?)
            output = mcoll_result.results[:data][:output]
            exitcode = mcoll_result.results[:data][:exitcode]
            raise OpenShift::NodeException.new("Failed to get quota for user: #{output}", 143) unless exitcode == 0
          else
            raise OpenShift::NodeException.new("Node execution failure (error getting result from node).  If the problem persists please contact Red Hat support.", 143)
          end
        else
          raise OpenShift::NodeException.new("Node execution failure (error getting result from node).  If the problem persists please contact Red Hat support.", 143)
        end
        output
      end
      
      # <<object method>>
      #
      # <<attribute setter>>
      #
      # Set blocks hard limit and inodes hard limit for uuid.
      # Effects disk quotas on Gear on Node
      # 
      # INPUT:
      # * gear: A Gear object
      # * storage_in_gb: integer
      # * inodes: integer
      #
      # RETURNS
      # * Not sure, mcoll_result? a string?
      #
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES:
      # * a pair of attribute setters on a Gear object
      #
      def set_quota(gear, storage_in_gb, inodes)
        args = Hash.new
        args['--uuid']   = gear.uuid
        # quota command acts on 1K blocks
        args['--blocks'] = Integer(storage_in_gb * 1024 * 1024)
        args['--inodes'] = inodes unless inodes.nil?
        reply = execute_direct(@@C_CONTROLLER, 'set-quota', args, false)

        output = nil
        exitcode = 0
        if reply and reply.length > 0
          mcoll_result = reply[0]
          if (mcoll_result && (defined? mcoll_result.results) && !mcoll_result.results[:data].nil?)
            output = mcoll_result.results[:data][:output]
            exitcode = mcoll_result.results[:data][:exitcode]
            raise OpenShift::NodeException.new("Failed to set quota for user: #{output}", 143) unless exitcode == 0
          else
            raise OpenShift::NodeException.new("Node execution failure (error getting result from node).  If the problem persists please contact Red Hat support.", 143)
          end
        else
          raise OpenShift::NodeException.new("Node execution failure (error getting result from node).  If the problem persists please contact Red Hat support.", 143)
        end
      end

      # Reserve a UID within a district or service
      #
      # UIDs must be unique in a district to allow migration without requiring
      # reassigning Username (Gear UUID) and Unix User UID on migrate
      # Perhaps a query on the nodes for "next UID"?
      #
      # INPUTS:
      # * district_uuid: String: District handle or identifier
      # * preferred_uid: Integer
      #
      # RAISES:
      # * OpenShift::OOException
      #
      # NOTES:
      # * a method on District class of the node.
      # 
      def reserve_uid(district_uuid=nil, preferred_uid=nil)
        reserved_uid = nil
        if Rails.configuration.msg_broker[:districts][:enabled]
          if @district
            district_uuid = @district.uuid
          else
            district_uuid = get_district_uuid unless district_uuid
          end
          if district_uuid && district_uuid != 'NONE'
            reserved_uid = District::reserve_uid(district_uuid, preferred_uid)
            raise OpenShift::OOException.new("uid could not be reserved in target district '#{district_uuid}'.  Please ensure the target district has available capacity.") unless reserved_uid
          end
        end
        reserved_uid
      end

      # Release a UID reservation within a District
      #
      # UIDs must be unique in a district to allow migration without requiring
      # reassigning Username (Gear UUID) and Unix User UID on migrate
      # Perhaps a query on the nodes for "next UID"?
      #
      # INPUTS:
      # * uid: Integer - the UID to unreserve within the district
      # * district_uuid: String - district handle or identifier
      #
      # NOTES:
      # * method on the District object.
      #
      def unreserve_uid(uid, district_uuid=nil)
        if Rails.configuration.msg_broker[:districts][:enabled]
          if @district
            district_uuid = @district.uuid
          else
            district_uuid = get_district_uuid unless district_uuid
          end
          if district_uuid && district_uuid != 'NONE'
            #cleanup
            District::unreserve_uid(district_uuid, uid)
          end
        end
      end
      
      def build_base_gear_args(gear, quota_blocks=nil, quota_files=nil)
        app = gear.app
        args = Hash.new
        args['--with-app-uuid'] = app.uuid
        args['--with-app-name'] = app.name
        args['--with-container-uuid'] = gear.uuid
        args['--with-container-name'] = gear.name
        args['--with-quota-blocks'] = quota_blocks if quota_blocks
        args['--with-quota-files'] = quota_files if quota_files
        args['--with-namespace'] = app.domain.namespace
        args['--with-uid'] = gear.uid if gear.uid
        args['--with-request-id'] = Thread.current[:user_action_log_uuid]
        args
      end

      def build_base_component_args(component, existing_args={})
        cart = component.cartridge_name
        existing_args['--cart-name'] = cart
        existing_args['--component-name'] = component.component_name
        existing_args['--with-software-version'] = component.version
        existing_args['--cartridge-vendor'] = component.cartridge_vendor
        if not component.cartridge_vendor.empty?
          clist = cart.split('-')
          if clist[0]==component.cartridge_vendor.to_s
            existing_args['--cart-name'] = clist[1..-1].join('-')
          end
        end
        existing_args
      end

      #
      # <<instance method>>
      # 
      # Execute the 'app-create' script on a node.
      #
      # INPUTS:
      # * gear: a Gear object
      # * quota_blocks: Integer - max file space in blocks
      # * quota_files: Integer - max files count
      # 
      # RETURNS:
      # * MCollective "result", stdout and exit code
      #
      # NOTES:
      # * uses execute_direct
      # * should raise an exception on fail to cause revert rather than in-line
      # * causes oo-app-create to execute on a node
      #
      # Constructs a shell command line to be executed by the MCollective agent
      # on the node.
      #      
      def create(gear, quota_blocks=nil, quota_files=nil)
        app = gear.app
        result = nil
        (1..10).each do |i|                    
          args = build_base_gear_args(gear, quota_blocks, quota_files)
          mcoll_reply = execute_direct(@@C_CONTROLLER, 'app-create', args)
          
          begin
            result = parse_result(mcoll_reply, gear)
          rescue OpenShift::OOException => ooex
            # destroy the gear in case of failures
            # the UID will be unreserved up as part of rollback
            destroy(gear, true)
            
            # raise the exception if this is the last retry
            raise ooex if i == 10
            
            result = ooex.resultIO
            if result.exitcode == 129 && has_uid_or_gid?(gear.uid) # Code to indicate uid already taken
              gear.uid = reserve_uid
              app.save
            else
              raise ooex
            end
          else
            break
          end
        end
        result
      end
    
      #
      # Remove a gear from a node
      # Optionally release a reserved UID from the District.
      #
      # INPUTS:
      # * gear: a Gear object
      # * keep_uid: boolean
      # * uid: Integer: reserved UID
      # * skip_hooks: boolean
      #
      # RETURNS:
      # * STDOUT from the remote command
      #
      # NOTES:
      # * uses execute_direct
      #
      def destroy(gear, keep_uid=false, uid=nil, skip_hooks=false)
        args = build_base_gear_args(gear)
        args['--skip-hooks'] = true if skip_hooks
        result = execute_direct(@@C_CONTROLLER, 'app-destroy', args)
        result_io = parse_result(result, gear)

        uid = gear.uid unless uid
        
        if uid && !keep_uid
          unreserve_uid(uid)
        end
        return result_io
      end

      # Add an SSL certificate to a gear on the remote node and associate it with
      # a server name.
      # See node/bin/oo-ssl-cert-add
      #
      # INPUTS:
      # * gear: a Gear object
      # * priv_key: String - the private key value
      # * server_alias: String - the name of the server which will offer this key
      # * passphrase: String - the private key passphrase or '' if its unencrypted.
      # 
      # RETURNS: a parsed MCollective result
      #
      # NOTES:
      # * calls node script oo-ssl-cert-add
      #
      def add_ssl_cert(gear, ssl_cert, priv_key, server_alias, passphrase='')
        args = build_base_gear_args(gear)
        args['--with-ssl-cert']       = ssl_cert
        args['--with-priv-key']       = priv_key
        args['--with-alias-name']     = server_alias
        args['--with-passphrase']     = passphrase
        result = execute_direct(@@C_CONTROLLER, 'ssl-cert-add', args)
        parse_result(result)
      end

      # remove an SSL certificate to a gear on the remote node.
      # See node/bin/oo-ssl-cert-remove
      #
      # INPUTS:
      # * gear: a Gear object
      # * server_alias: String - the name of the server which will offer this key
      # 
      # RETURNS: a parsed MCollective result
      #
      # NOTES:
      # * calls node script oo-ssl-cert-remove
      #
      def remove_ssl_cert(gear, server_alias)
        args = build_base_gear_args(gear)
        args['--with-alias-name']     = server_alias
        result = execute_direct(@@C_CONTROLLER, 'ssl-cert-remove', args)
        parse_result(result)
      end

      # 
      # Add an ssh key to a gear on the remote node.
      # See node/bin/oo-authorized-ssh-key-add.
      #
      # INPUTS:
      # * gear: a Gear object
      # * ssh_key: String - an SSH RSA or DSA public key string
      # * key_type: String, Enum [rsa|dsa]
      # * comment: String - identify the key
      #
      # RETURNS:
      # * MCollective result string: STDOUT from a command.
      #
      # NOTES:
      # * uses execute_direct
      # * calls oo-authorized-ssh-key-add on the node
      #
      def add_authorized_ssh_key(gear, ssh_key, key_type=nil, comment=nil)
        args = build_base_gear_args(gear)
        args['--with-ssh-key'] = ssh_key
        args['--with-ssh-key-type'] = key_type if key_type
        args['--with-ssh-key-comment'] = comment if comment
        result = execute_direct(@@C_CONTROLLER, 'authorized-ssh-key-add', args)
        parse_result(result, gear)
      end

      #
      # remove an ssh key from a gear on a remote node.
      # See node/bin/oo-authorized-ssh-key-remove
      #
      # INPUTS:
      # * gear: a Gear object
      # * ssh_key: String - an SSH RSA or DSA public key string
      # * comment: String - identify the key
      #
      # RETURNS:
      # * MCollective result string: STDOUT from a command.
      #
      # NOTES:
      # * uses execute_direct
      # * calls oo-authorized-ssh-key-remove on the node
      #
      def remove_authorized_ssh_key(gear, ssh_key, comment=nil)
        args = build_base_gear_args(gear)
        args['--with-ssh-key'] = ssh_key
        args['--with-ssh-comment'] = comment if comment
        result = execute_direct(@@C_CONTROLLER, 'authorized-ssh-key-remove', args)
        parse_result(result, gear)
      end


      #
      # Add an environment variable on gear on a remote node.
      # Calls oo-env-var-add on the remote node
      #
      # INPUTS:
      # * gear: a Gear object
      # * key: String - environment variable name
      # * value: String - environment variable value
      #
      # RETURNS:
      # * MCollective result string: STDOUT from a command.
      #
      # NOTES:
      # * uses execute_direct
      # * calls oo-env-var-add on the node
      # * Should be a method on Gear?
      #
      def add_env_var(gear, key, value)
        args = build_base_gear_args(gear)
        args['--with-key'] = key
        args['--with-value'] = value
        result = execute_direct(@@C_CONTROLLER, 'env-var-add', args)
        parse_result(result, gear)
      end

      #
      # Remove an environment variable on gear on a remote node
      #
      # INPUTS:
      # * gear: a Gear object
      # * key: String - environment variable name
      #
      # RETURNS:
      # * MCollective result string: STDOUT from a command.
      #
      # NOTES:
      # * uses execute_direct
      # * calls oo-env-var-remove on the node
      #      
      def remove_env_var(gear, key)
        args = build_base_gear_args(gear)
        args['--with-key'] = key
        result = execute_direct(@@C_CONTROLLER, 'env-var-remove', args)
        parse_result(result, gear)
      end

      #
      # Add a broker auth key.  The broker auth key allows an application 
      # to request scaling and other actions from the broker.
      #
      # INPUTS:
      # * gear: a Gear object
      # * iv: String - SSL initialization vector
      # * token: String - a broker auth key
      #
      # RETURNS:
      # * mcollective parsed result string (stdout)
      #
      # NOTES:
      # * uses execute_direct
      # * calls oo-broker-auth-key-add
      #
      def add_broker_auth_key(gear, iv, token)
        args = build_base_gear_args(gear)
        args['--with-iv'] = iv
        args['--with-token'] = token
        result = execute_direct(@@C_CONTROLLER, 'broker-auth-key-add', args)
        parse_result(result, gear)
      end

      #
      # Remove a broker auth key. The broker auth key allows an application 
      # to request scaling and other actions from the broker.
      #
      # INPUTS:
      # * gear: a Gear object
      #
      # RETURNS:
      # * mcollective parsed result string (stdout)
      #
      # NOTES:
      # * uses execute_direct
      # * calls oo-broker-auth-key-remove
      #    
      def remove_broker_auth_key(gear)
        args = build_base_gear_args(gear)
        result = execute_direct(@@C_CONTROLLER, 'broker-auth-key-remove', args)
        parse_result(result, gear)
      end


      # 
      # Get the operating state of a gear
      # 
      # INPUTS:
      # * gear: Gear Object
      # 
      # RETURNS:
      # * mcollective result string (stdout)
      #
      # NOTES:
      # * uses execute_direct
      # * calls oo-app-state-show
      # * Should be a method on Gear object
      #
      def show_state(gear)
        args = build_base_gear_args(gear)
        result = execute_direct(@@C_CONTROLLER, 'app-state-show', args)
        parse_result(result, gear)
      end
      
      # 
      # Install a cartridge in a gear.
      # If the cart is a 'framework' cart, create the gear first.
      #
      # A 'framework' cart:
      # * Runs a service which,
      # * answers HTTP queries for content
      # * gets a new DNS record
      # * does not require an existing gear
      # 
      # An 'embedded' cart:
      # * Requires an existing gear
      # * depends on an existing framework cart
      # * Interacts with the service from a framework cart
      # * does not serve http *content* (can proxy)
      # 
      # INPUTS:
      # * gear: a Gear object
      # * component: a component_instance object
      # * template_git_url: a url of a git repo containing a cart overlay
      #
      # RETURNS
      # the result of either run_cartridge_command or add_component
      #
      # Framework carts just return result_io
      # Embedded carts return an array [result_io, cart_data]
      #
      # NOTES:
      # * should return consistant values
      # * cart data request should be separate method?
      # * create Gear should be a method on Node object
      # * should not cause node side Gear side effect
      # * should be a method on Gear object
      # * should not include incoherent template install 
      # * calls *either* run_cartridge_command or add_component
      #
      def configure_cartridge(gear, component, template_git_url=nil)
        result_io = ResultIO.new
        cart_data = nil
        
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)

        app = gear.app
        downloaded_cart =  app.downloaded_cart_map.values.find { |c| c["versioned_name"]==component.cartridge_name}
        if downloaded_cart
          args['--with-cartridge-manifest'] = downloaded_cart["original_manifest"]
          args['--with-software-version'] = downloaded_cart["version"]
        end
        
        if !template_git_url.nil?  && !template_git_url.empty?
          args['--with-template-git-url'] = template_git_url
        end

        if framework_carts(app).include? component.cartridge_name
          result_io = run_cartridge_command(component.cartridge_name, gear, "configure", args)
        elsif embedded_carts(app).include? component.cartridge_name
          result_io, cart_data = add_component(gear, component.cartridge_name, args)
        else
          #no-op
        end
        
        return result_io#, cart_data
      end
      
      # 
      # Post configuration for a cartridge on a gear.
      #
      # INPUTS:
      # * gear: a Gear object
      # * component: component_instance object
      # * template_git_url: a url of a git repo containing a cart overlay
      #
      # RETURNS
      # ResultIO: the result of running post-configuration on the cartridge
      #
      def post_configure_cartridge(gear, component, template_git_url=nil)
        result_io = ResultIO.new
        cart_data = nil
        cart = component.cartridge_name
        
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        
        if !template_git_url.nil?  && !template_git_url.empty?
          args['--with-template-git-url'] = template_git_url
        end

        if framework_carts(gear.app).include?(cart) or embedded_carts(gear.app).include?(cart)
          result_io = run_cartridge_command(cart, gear, "post-configure", args)
        else
          #no-op
        end
        
        return result_io
      end
      
      #
      # Remove a Gear and the last contained cartridge from a node
      # 
      # INPUTS
      # * gear: a Gear object
      # * component: a component_instance object
      # 
      # RETURNS:
      # * result of run_cartridge_command 'deconfigure' OR remove_component
      # * OR an empty result because the cartridge was invalid
      #
      # NOTES:
      # * This is really two operations:
      # ** remove_cartridge on Gear
      # ** remove_gear on Node
      # * should raise an exception for invalid gear?
      # 
      def deconfigure_cartridge(gear, component)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)

        if framework_carts(gear.app).include? cart
          run_cartridge_command(cart, gear, "deconfigure", args)
        elsif embedded_carts(gear.app).include? cart
          remove_component(gear,component)
        else
          ResultIO.new
        end        
      end
      
      # <<accessor>>
      # Get the public hostname of a Node
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * String: the public hostname of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #
      def get_public_hostname
        rpc_get_fact_direct('public_hostname')
      end
      
      # <<accessor>>
      # Get the "capacity" of a node
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * Float: the "capacity" of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #
      def get_capacity
        rpc_get_fact_direct('capacity').to_f
      end
      
      # <<accessor>>
      # Get the "active capacity" of a node
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * Float: the "active capacity" of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #
      def get_active_capacity
        rpc_get_fact_direct('active_capacity').to_f
      end
      
      # <<accessor>>
      # Get the district UUID (membership handle) of a node
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * String: the UUID of a node's district
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #
      def get_district_uuid
        rpc_get_fact_direct('district_uuid')
      end
      
      # <<accessor>>
      # Get the public IP address of a Node
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * String: the public IP address of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #
      def get_ip_address
        rpc_get_fact_direct('ipaddress')
      end
      

      # <<accessor>>
      # Get the public IP address of a Node
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * String: the public IP address of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #
      def get_public_ip_address
        rpc_get_fact_direct('public_ip')
      end

      # <<accessor>>
      # Get the "node profile" of a Node
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * String: the "node profile" of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #      
      def get_node_profile
        rpc_get_fact_direct('node_profile')
      end

      # <<accessor>>
      # Get the quota blocks of a Node
      #
      # Is this disk available or the default quota limit?
      # It's from Facter.
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * String: the "quota blocks" of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #      
      def get_quota_blocks
        rpc_get_fact_direct('quota_blocks')
      end

      # <<accessor>>
      # Get the quota files of a Node
      #
      # Is this disk available or the default quota limit?
      # It's from Facter.
      #
      # INPUTS:
      # none
      #
      # RETURNS:
      # * String: the "quota files" of a node
      #
      # NOTES:
      # * method on Node
      # * calls rpc_get_fact_direct
      #      
      def get_quota_files
        rpc_get_fact_direct('quota_files')
      end

      #
      # Start cartridge services within a gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a ResultIO of undetermined state
      #
      # NOTES:
      # * uses run_cartridge_command
      # * uses start_component
      # * should be a method on Gear?
      #
      def start(gear, component)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)

        run_cartridge_command_ignore_components(cart, gear, "start", args)
      end

      def get_start_job(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        RemoteJob.new('openshift-origin-node', 'start', args)
      end

      #
      # Stop cartridge services within a gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a ResultIO of undetermined state
      #
      # NOTES:
      # * uses run_cartridge_command
      # * uses stop_component
      # * uses start_component
      # * should be a method on Gear?
      #      
      def stop(gear, component)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)

        run_cartridge_command_ignore_components(cart, gear, "stop", args)
      end
      
      # 
      # Force gear services to stop
      # 
      # INPUTS:
      # * gear: Gear object
      # * cart: Cartridge object
      #
      # RETURNS:
      # * result string from STDOUT
      #
      # NOTES:
      # * uses execute_direct
      # * calls force-stop
      # * method on Node?
      #
      def force_stop(gear, cart)
        args = build_base_gear_args(gear)
        result = execute_direct(@@C_CONTROLLER, 'force-stop', args)
        parse_result(result)
      end
      
      #
      # Stop and restart cart services on a gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      # 
      # RETURNS:
      # * a ResultIO of undefined content
      #
      # NOTES:
      # * uses run_cartridge_command
      # * uses restart_component
      # * method on Gear?
      #
      def restart(gear, component)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)
        
        run_cartridge_command_ignore_components(cart, gear, "restart", args)
      end
      

      #
      # "reload" cart services on a gear.
      # Accept config update without restarting?
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      # 
      # RETURNS:
      # * a ResultIO of undefined content
      #
      # NOTES:
      # * uses run_cartridge_command
      # * uses restart_component
      # * method on Gear?
      #      
      def reload(gear, component)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)

        run_cartridge_command_ignore_components(cart, gear, "reload", args)
      end
 
      #
      # Get the status from cart services in an existing Gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * A ResultIO object of undetermined content
      #
      # NOTES:
      # * method on gear or cartridge?
      # * uses run_cartridge_command
      # * component_status
      #
      def status(gear, component)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)

        run_cartridge_command_ignore_components(cart, gear, "status", args)
      end
 
      #
      # Clean up unneeded artifacts in a gear
      # 
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * String: stdout from a command
      #
      # NOTES
      # * calls the 'tidy' hook on a Gear or app?
      # * doesn't use cart input
      # * calls execute_direct
      #
      def tidy(gear, component)
        args = build_base_gear_args(gear)
        result = execute_direct(@@C_CONTROLLER, 'tidy', args)
        parse_result(result)
      end
      
      #
      # dump the cartridge threads
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a ResultIO of undetermined content
      #
      # NOTES:
      # * calls run_cartridge_command
      # * method on Gear or Cart?
      #
      def threaddump(gear, component)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)

        if framework_carts(gear.app).include?(cart)
          run_cartridge_command(cart, gear, "threaddump", args)
        else
          ResultIO.new
        end 
      end

      #
      # "retrieve the system messages"
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a ResultIO of undetermined content
      #
      # NOTES:
      # * calls run_cartridge_command
      # * method on Gear or Cart?
      # * only applies to the "framework" services
      #      
      def system_messages(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)

        if framework_carts(gear.app).include?(cart)
          run_cartridge_command(cart, gear, "system-messages", args)
        else
          ResultIO.new
        end 
      end

      #
      # expose a TCP port
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a ResultIO of undetermined content
      #
      # NOTES:
      # * calls run_cartridge_command
      # * executes 'expose-port' action.
      # * method on Gear or Cart?
      #            
      def get_expose_port_job(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        RemoteJob.new('openshift-origin-node', 'expose-port', args)
      end
      
      def get_conceal_port_job(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        RemoteJob.new('openshift-origin-node', 'conceal-port', args)
      end
      
      def get_show_port_job(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        RemoteJob.new('openshift-origin-node', 'show-port', args)
      end
      
      def expose_port(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        result = execute_direct(@@C_CONTROLLER, 'expose-port', args)
        parse_result(result)
      end

      #
      # hide a TCP port (?)
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a ResultIO of undetermined content
      #
      # NOTES:
      # * calls run_cartridge_command
      # * executes "conceal-port" action.
      # * method on Gear or Cart?
      #            
      # Deprecated: remove from the REST API and then delete this.
      def conceal_port(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        result = execute_direct(@@C_CONTROLLER, 'conceal-port', args)
        parse_result(result)
      end

      #
      # get information on a TCP port
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a ResultIO of undetermined content
      #
      # NOTES:
      # * calls run_cartridge_command
      # * executes "show-port" action
      # * method on Gear or Cart?
      #            
      # Deprecated: remove from the REST API and then delete this.
      def show_port(gear, cart)
        ResultIO.new
      end
      
      # 
      # Add an application alias to a gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * server_alias: String - a new FQDN for the gear
      # 
      # RETURNS:
      # * String: stdout from a command
      # 
      # NOTES:
      # * calls execute_direct
      # * executes the 'add-alias' action on the node
      # * method on Gear?
      #
      def add_alias(gear, server_alias)
        args = build_base_gear_args(gear)
        args['--with-alias-name']=server_alias
        result = execute_direct(@@C_CONTROLLER, 'add-alias', args)
        parse_result(result)
      end
      
      # 
      # remove an application alias to a gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * server_alias: String - a new FQDN for the gear
      # 
      # RETURNS:
      # * String: stdout from a command
      # 
      # NOTES:
      # * calls execute_direct
      # * executes the 'remove-alias' action on the gear.
      # * method on Gear?
      #
      def remove_alias(gear, server_alias)
        args = build_base_gear_args(gear)
        args['--with-alias-name']=server_alias
        result = execute_direct(@@C_CONTROLLER, 'remove-alias', args)
        parse_result(result)        
      end
      
      #
      # Extracts the frontend httpd server configuration from a gear.
      #
      # INPUTS:
      # * gear: a Gear object
      #
      # RETURNS:
      # * String - backup blob from the front-end server
      #
      # NOTES:
      # * uses execute_direct
      # * executes the 'frontend-backup' action on the gear.
      # * method on the FrontendHttpd class
      #
      #
      def frontend_backup(gear)
        app = gear.app
        args = Hash.new
        args['--with-container-uuid']=gear.uuid
        args['--with-container-name']=gear.name
        args['--with-namespace']=app.domain.namespace
        result = execute_direct(@@C_CONTROLLER, 'frontend-backup', args)
        result = parse_result(result)
        result.resultIO.string
      end

      #
      # Transmits the frontend httpd server configuration to a gear.
      #
      # INPUTS:
      # * backup: string which was previously returned by frontend_backup
      #
      # RETURNS:
      # * String - "parsed result" of an MCollective reply
      #
      # NOTES:
      # * uses execute_direct
      # * executes the 'frontend-backup' action on the gear.
      # * method on the FrontendHttpd class
      #
      #
      def frontend_restore(backup)
        result = execute_direct(@@C_CONTROLLER, 'frontend-restore', {'--with-backup' => backup})
        parse_result(result)
      end

      #
      # Get status on an add env var job?
      #
      # INPUTS:
      # * gear: a Gear object
      # * key: an environment variable name
      # * value: and environment variable value
      # 
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      # 
      def get_env_var_add_job(gear, key, value)
        args = build_base_gear_args(gear)
        args['--with-key'] = key
        args['--with-value'] = value
        job = RemoteJob.new('openshift-origin-node', 'env-var-add', args)
        job
      end

      #
      # Create a job to remove an environment variable
      #
      # INPUTS:
      # * gear: a Gear object
      # * key: an environment variable name
      # * value: and environment variable value
      # 
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      # 
      def get_env_var_remove_job(gear, key)
        args = build_base_gear_args(gear)
        args['--with-key'] = key
        job = RemoteJob.new('openshift-origin-node', 'env-var-remove', args)
        job
      end
  
      #
      # Create a job to add an authorized key
      #
      # INPUTS:
      # * gear: a Gear object
      # * ssh_key: String - SSH public key string
      # * key_type: String, Enum [dsa|rsa]
      # * comment: String
      # 
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      # 
      def get_add_authorized_ssh_key_job(gear, ssh_key, key_type=nil, comment=nil)
        args = build_base_gear_args(gear)
        args['--with-ssh-key'] = ssh_key
        args['--with-ssh-key-type'] = key_type if key_type
        args['--with-ssh-key-comment'] = comment if comment
        job = RemoteJob.new('openshift-origin-node', 'authorized-ssh-key-add', args)
        job
      end

      #
      # Create a job to remove an authorized key.
      #
      # INPUTS:
      # * gear: a Gear object
      # * ssh_key: String - SSH public key string
      # * comment: String
      # 
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      #       
      def get_remove_authorized_ssh_key_job(gear, ssh_key, comment=nil)
        args = build_base_gear_args(gear)
        args['--with-ssh-key'] = ssh_key
        args['--with-ssh-comment'] = comment if comment
        job = RemoteJob.new('openshift-origin-node', 'authorized-ssh-key-remove', args)
        job
      end

      #
      # Create a job to remove existing authorized ssh keys and add the provided ones to the gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * ssh_keys: Array - SSH public key list
      # 
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      # 
      def get_fix_authorized_ssh_keys_job(gear, ssh_keys)
        args = build_base_gear_args(gear)
        args['--with-ssh-keys'] = ssh_keys.map {|k| {'key' => k['content'], 'type' => k['type'], 'comment' => k['name']}}
        job = RemoteJob.new('openshift-origin-node', 'authorized-ssh-keys-replace', args)
        job
      end

      #
      # Create a job to add a broker auth key
      #
      # INPUTS:
      # * gear: a Gear object
      # * iv: ??
      # * token: ??
      # 
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      #       
      def get_broker_auth_key_add_job(gear, iv, token)
        args = build_base_gear_args(gear)
        args['--with-iv'] = iv
        args['--with-token'] = token
        job = RemoteJob.new('openshift-origin-node', 'broker-auth-key-add', args)
        job
      end

      #
      # Create a job to remove a broker auth key
      #
      # INPUTS:
      # * gear: a Gear object
      # 
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      #         
      def get_broker_auth_key_remove_job(gear)
        args = build_base_gear_args(gear)
        job = RemoteJob.new('openshift-origin-node', 'broker-auth-key-remove', args)
        job
      end

      #
      # Create a job to execute a connector hook ??
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      # * connector_name: String
      # * input_args: Array of String
      #
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      # 
      def get_execute_connector_job(gear, component, connector_name, connection_type, input_args, pub_cart=nil)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)
        args['--hook-name'] = connector_name
        args['--publishing-cart-name'] = pub_cart if pub_cart
        args['--connection-type'] = connection_type
        # Need to pass down args as hash for subscriber ENV hooks only
        if connection_type.start_with?("ENV:") && pub_cart
          args['--input-args'] = input_args
        else
          args['--input-args'] = input_args.join(" ")
        end
        job = RemoteJob.new('openshift-origin-node', 'connector-execute', args)
        job
      end

      #
      # Create a job to unsubscribe
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      # * publish_cart_name: a Cartridge object
      #
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      # 
      def get_unsubscribe_job(gear, component, publish_cart_name)
        args = build_base_gear_args(gear)
        cart = component.cartridge_name
        args = build_base_component_args(component, args)
        args['--publishing-cart-name'] = publish_cart_name
        job = RemoteJob.new('openshift-origin-node', 'unsubscribe', args)
        job
      end

      #
      # Create a job to return the state of a gear
      #
      # INPUTS:
      # * gear: a Gear object
      #
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      #         
      def get_show_state_job(gear)
        args = build_base_gear_args(gear)
        job = RemoteJob.new('openshift-origin-node', 'app-state-show', args)
        job
      end


      #
      # Create a job to get status of an application
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: a Cartridge object
      #
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      #         
      def get_status_job(gear, component)
        args = build_base_gear_args(gear)
        job = RemoteJob.new(component.cartridge_name, 'status', args)
        job
      end

      #
      # Create a job to check the disk quota on a gear
      #
      # INPUTS:
      # * gear: a Gear object
      #
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      #         
      def get_show_gear_quota_job(gear)
        args = Hash.new
        args['--uuid'] = gear.uuid
        job = RemoteJob.new('openshift-origin-node', 'get-quota', args)
        job
      end

      #
      # Create a job to change the disk quotas on a gear
      #
      # INPUTS:
      # * gear: a Gear object
      #
      # RETURNS:
      # * a RemoteJob object
      #
      # NOTES:
      # * uses RemoteJob
      #               
      def get_update_gear_quota_job(gear, storage_in_gb, inodes)
        args = Hash.new
        args['--uuid']   = gear.uuid
        # quota command acts on 1K blocks
        args['--blocks'] = Integer(storage_in_gb * 1024 * 1024)
        args['--inodes'] = inodes unless inodes.to_s.empty?
        job = RemoteJob.new('openshift-origin-node', 'set-quota', args)
        job
      end
      
      # 
      # Re-start a gear after migration
      #
      # INPUTS:
      # * gear: a Gear object
      # * destination_container: an ApplicationContainerProxy object?
      # * state_map: ??
      #
      # RETURNS:
      # * ResultIO
      #
      # NOTES:
      # * uses OpenShift::DnsService
      # * 
      #
      # 
      def move_gear_post(gear, destination_container, state_map)
        app = gear.app
        reply = ResultIO.new
        gi = gear.group_instance
        gear_components = gi.all_component_instances
        start_order, stop_order = app.calculate_component_orders
        source_container = gear.get_proxy
        start_order.each do |cinst|
          next if not gear_components.include? cinst
          next if cinst.is_singleton? and (not gear.host_singletons)
          cart = cinst.cartridge_name
          idle, leave_stopped = state_map[cart]
          unless leave_stopped
            log_debug "DEBUG: Starting cartridge '#{cart}' in '#{app.name}' after move on #{destination_container.id}"
            args = build_base_gear_args(gear)
            args = build_base_component_args(cinst, args)
            reply.append destination_container.send(:run_cartridge_command, cart, gear, "start", args, false)
          end
        end

        log_debug "DEBUG: Fixing DNS and mongo for gear '#{gear.name}' after move"
        log_debug "DEBUG: Changing server identity of '#{gear.name}' from '#{source_container.id}' to '#{destination_container.id}'"
        gear.server_identity = destination_container.id
        gear.group_instance.gear_size = destination_container.get_node_profile
        begin
          dns = OpenShift::DnsService.instance
          public_hostname = destination_container.get_public_hostname
          dns.modify_application(gear.name, app.domain.namespace, public_hostname)
          dns.publish
        ensure
          dns.close
        end
        reply
      end

      #
      # Prepare to move a gear from one node to another
      #
      # INPUTS:
      # * gear: A Gear object
      # * state_map: ??
      #
      # RETURNS:
      # * a ResultIO object
      #
      # NOTES:
      # * uses ResultIO
      # * ResultIO is *composed*
      # * uses Container (from gear)
      #
      def move_gear_pre(gear, state_map)
        app = gear.app
        reply = ResultIO.new
        source_container = gear.get_proxy
        gi_comps = gear.group_instance.all_component_instances.to_a
        start_order,stop_order = app.calculate_component_orders
        stop_order.each { |cinst|
          next if not gi_comps.include? cinst
          next if cinst.is_singleton? and (not gear.host_singletons)
          cart = cinst.cartridge_name
          idle, leave_stopped = state_map[cart]
          # stop the cartridge if it needs to
          unless leave_stopped
            log_debug "DEBUG: Stopping existing app cartridge '#{cart}' before moving"
            begin
              do_with_retry('stop') do
                reply.append source_container.stop(gear, cinst)
              end
            rescue Exception=>e
              # a force-stop will be applied if its a framework cartridge, so ignore the failure on stop
              if not framework_carts(app).include? cart
                raise e
              end
            end
            if framework_carts(app).include? cart
              log_debug "DEBUG: Force stopping existing app cartridge '#{cart}' before moving"
              do_with_retry('force-stop') do
                reply.append source_container.force_stop(gear, cinst)
              end
            end
          end
        }
        reply
      end

      #
      # Move a gear from one node to another
      # 
      # INPUTS
      # * gear: a Gear object
      # * destination_container: An ApplicationContainerProxy?
      # * destination_district_uuid: String
      # * change_district: Boolean
      # * node_profile: String
      # 
      # RETURNS:
      # * ResultIO 
      # 
      # RAISES:
      # * OpenShift::UserException
      #
      # CATCHES:
      # * Exception
      #
      # NOTES:
      # * uses resolve_destination
      # * uses rsync_destination_container
      # * uses move_gear_destroy_old
      # 
      def move_gear_secure(gear, destination_container, destination_district_uuid, change_district, node_profile)
        app = gear.app
        Application.run_in_application_lock(app) do
          move_gear(gear, destination_container, destination_district_uuid, change_district, node_profile)
        end
      end

      def move_gear(gear, destination_container, destination_district_uuid, change_district, node_profile)
        app = gear.app
        reply = ResultIO.new
        state_map = {}

        # resolve destination_container according to district
        destination_container, destination_district_uuid, district_changed = resolve_destination(gear, destination_container, destination_district_uuid, change_district, node_profile)

        source_container = gear.get_proxy

        if source_container.id == destination_container.id
          log_debug "Cannot move a gear within the same node. The source container and destination container are the same."
          raise OpenShift::UserException.new("Error moving app. Destination container same as source container.", 1)
        end

        destination_node_profile = destination_container.get_node_profile
        if source_container.get_node_profile != destination_node_profile and app.scalable
          log_debug "Cannot change node_profile for *scalable* application gear - this operation is not supported. The destination container's node profile is #{destination_node_profile}, while the gear's node_profile is #{gear.group_instance.gear_size}"
          raise OpenShift::UserException.new("Error moving app.  Cannot change node profile for *scalable* app.", 1)
        end

        # get the state of all cartridges
        quota_blocks = nil
        quota_files = nil
        idle, leave_stopped, quota_blocks, quota_files = get_app_status(app)
        gi = gear.group_instance
        gi.all_component_instances.each do |cinst|
          next if cinst.is_singleton? and (not gear.host_singletons)
          state_map[cinst.cartridge_name] = [idle, leave_stopped]
        end

        begin
          # pre-move
          reply.append move_gear_pre(gear, state_map)

          if district_changed
            destination_container.reserve_uid(destination_district_uuid, gear.uid)
            log_debug "DEBUG: Reserved uid '#{gear.uid}' on district: '#{destination_district_uuid}'"
          end
          begin
            # rsync gear with destination container
            rsync_destination_container(gear, destination_container, destination_district_uuid, quota_blocks, quota_files)

            start_order,stop_order = app.calculate_component_orders
            gi_comps = gear.group_instance.all_component_instances.to_a
            start_order.each do |cinst|
              next if not gi_comps.include? cinst
              next if cinst.is_singleton? and (not gear.host_singletons)
              cart = cinst.cartridge_name
              idle, leave_stopped = state_map[cart]

              if app.scalable and not CartridgeCache.find_cartridge(cart).categories.include? "web_proxy"
                begin
                  reply.append destination_container.expose_port(gear, cinst)
                rescue Exception=>e
                  # just pass because some embedded cartridges do not have expose-port hook implemented (e.g. jenkins-client)
                end
              end
            end 

            # start the gears again and change DNS entry
            reply.append move_gear_post(gear, destination_container, state_map)
            # app.elaborate_descriptor
            app.execute_connections
            if app.scalable
              # execute connections restart the haproxy service, so stop it explicitly if needed
              stop_order.each do |cinst|
                next if not gi_comps.include? cinst
                cart = cinst.cartridge_name
                idle, leave_stopped = state_map[cart]
                if leave_stopped and CartridgeCache.find_cartridge(cart).categories.include? "web_proxy"
                  log_debug "DEBUG: Explicitly stopping cartridge '#{cart}' in '#{app.name}' after move on #{destination_container.id}"
                  reply.append destination_container.stop(gear, cinst)
                end
              end
            end
            app.save

          rescue Exception => e
            gear.server_identity = source_container.id
            gear.group_instance.gear_size = source_container.get_node_profile
            # remove-httpd-proxy of destination
            log_debug "DEBUG: Moving failed.  Rolling back gear '#{gear.name}' '#{app.name}' with remove-httpd-proxy on '#{destination_container.id}'"
            gi.all_component_instances.each do |cinst|
              next if cinst.is_singleton? and (not gear.host_singletons)
              cart = cinst.cartridge_name
              if framework_carts(app).include? cart
                begin
                  args = build_base_gear_args(gear)
                  args = build_base_component_args(cinst, args)
                  reply.append destination_container.send(:run_cartridge_command, cart, gear, "remove-httpd-proxy", args, false)
                rescue Exception => e
                  log_debug "DEBUG: Remove httpd proxy with cart '#{cart}' failed on '#{destination_container.id}'  - gear: '#{gear.name}', app: '#{app.name}'"
                end
              end
            end
            # destroy destination
            log_debug "DEBUG: Moving failed.  Rolling back gear '#{gear.name}' in '#{app.name}' with destroy on '#{destination_container.id}'"
            reply.append destination_container.destroy(gear, !district_changed, nil, true)
            raise
          end
        rescue Exception => e
          begin
            gi_comps = gear.group_instance.all_component_instances.to_a
            start_order,stop_order = app.calculate_component_orders
            # start source
            start_order.each do |cinst|
              next if not gi_comps.include? cinst
              next if cinst.is_singleton? and (not gear.host_singletons)
              cart = cinst.cartridge_name
              idle, leave_stopped = state_map[cart]
              if not leave_stopped
                args = build_base_gear_args(gear)
                args = build_base_component_args(cinst, args)
                reply.append source_container.run_cartridge_command(cart, gear, "start", args, false)
              end
            end
          ensure
            raise
          end
        end

        move_gear_destroy_old(gear, source_container, destination_container, district_changed)

        log_debug "Successfully moved gear with uuid '#{gear.uuid}' of app '#{app.name}' from '#{source_container.id}' to '#{destination_container.id}'"
        reply
      end

      # 
      # Remove and destroy a old gear after migration
      #
      # INPUTS:
      # * gear: a Gear object
      # * source_container: ??
      # * destination_container ??
      # * district_changed: boolean
      #
      # RETURNS:
      # * a ResultIO object
      # 
      # CATCHES:
      # * Exception
      #
      # NOTES:
      # * uses source_container.destroy
      # 
      def move_gear_destroy_old(gear, source_container, destination_container, district_changed)
        app = gear.app
        reply = ResultIO.new
        log_debug "DEBUG: Deconfiguring old app '#{app.name}' on #{source_container.id} after move"
        begin
          reply.append source_container.destroy(gear, !district_changed, gear.uid, true)
        rescue Exception => e
          log_debug "DEBUG: The application '#{app.name}' with gear uuid '#{gear.uuid}' is now moved to '#{destination_container.id}' but not completely deconfigured from '#{source_container.id}'"
          raise
        end
        reply
      end

      #
      # 
      # INPUTS:
      # * gear: a Gear object
      # * destination_container: ??
      # * destination_district_uuid: String
      # * change_district: Boolean
      # * node_profile: String
      #
      # RETURNS:
      # * Array: [destination_container, destination_district_uuid, district_changed]
      # 
      # RAISES:
      # * OpenShift::UserException
      #
      # NOTES:
      # * uses MCollectiveApplicationContainerProxy.find_available_impl
      #
      def resolve_destination(gear, destination_container, destination_district_uuid, change_district, node_profile)
        gear_exists_in_district = false
        required_uid = gear.uid
        source_container = gear.get_proxy
        source_district_uuid = source_container.get_district_uuid
 
        if node_profile and (destination_container or destination_district_uuid or !Rails.configuration.msg_broker[:node_profile_enabled])
          log_debug "DEBUG: Option node_profile '#{node_profile}' is being ignored either in favor of destination district/container "\
                    "or node_profile is disabled in msg broker configuration."
          node_profile = nil
        end
 
        if destination_container.nil?
          if !destination_district_uuid and !change_district
            destination_district_uuid = source_district_uuid unless source_district_uuid == 'NONE'
          end

          # Check to see if the gear's current district and the destination district are the same
          if (not destination_district_uuid.nil?) and (destination_district_uuid == source_district_uuid)
            gear_exists_in_district = true
            required_uid = nil
          end
          
          least_preferred_server_identities = [source_container.id]
          destination_gear_size = node_profile || gear.group_instance.gear_size
          destination_container = MCollectiveApplicationContainerProxy.find_available_impl(destination_gear_size, destination_district_uuid, nil, gear_exists_in_district, required_uid)
          log_debug "DEBUG: Destination container: #{destination_container.id}"
          destination_district_uuid = destination_container.get_district_uuid
        else
          if destination_district_uuid
            log_debug "DEBUG: Destination district uuid '#{destination_district_uuid}' is being ignored in favor of destination container #{destination_container.id}"
          end
          destination_district_uuid = destination_container.get_district_uuid
        end
        
        log_debug "DEBUG: Source district uuid: #{source_district_uuid}"
        log_debug "DEBUG: Destination district uuid: #{destination_district_uuid}"
        district_changed = (destination_district_uuid != source_district_uuid)

        if source_container.id == destination_container.id
          raise OpenShift::UserException.new("Error moving app.  Old and new servers are the same: #{source_container.id}", 1)
        end
        return [destination_container, destination_district_uuid, district_changed]
      end

      #
      # copy the file contents of a gear on this node to a new gear on another
      # 
      # INPUTS:
      # * gear: a Gear object
      # * destination_container: an ApplicationContainerProxxy object
      # * destination_district_uuid: String: a UUID handle
      # * quota_blocks: Integer
      # * quota_files: Integer
      #
      # RETURNS:
      # * ResultIO
      #
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES:
      # * uses broker configuration rsync_keyfile
      # * uses ssh-agent
      # * uses ssh-add
      # * uses rsync
      # * runs all three commands in a single backtick eval
      # * writes the eval output to log_debug
      #
      def rsync_destination_container(gear, destination_container, destination_district_uuid, quota_blocks, quota_files)
        app = gear.app
        reply = ResultIO.new
        source_container = gear.get_proxy
        log_debug "DEBUG: Creating new account for gear '#{gear.name}' on #{destination_container.id}"
        reply.append destination_container.create(gear, quota_blocks, quota_files)

        log_debug "DEBUG: Moving content for app '#{app.name}', gear '#{gear.name}' to #{destination_container.id}"
        rsync_keyfile = Rails.configuration.auth[:rsync_keyfile]
        log_debug `eval \`ssh-agent\`; ssh-add #{rsync_keyfile}; ssh -o StrictHostKeyChecking=no -A root@#{source_container.get_ip_address} "rsync -aAX -e 'ssh -o StrictHostKeyChecking=no' /var/lib/openshift/#{gear.uuid}/ root@#{destination_container.get_ip_address}:/var/lib/openshift/#{gear.uuid}/"; ssh-agent -k`
        if $?.exitstatus != 0
          raise OpenShift::NodeException.new("Error moving app '#{app.name}', gear '#{gear.name}' from #{source_container.id} to #{destination_container.id}", 143)
        end

        log_debug "DEBUG: Moving system components for app '#{app.name}', gear '#{gear.name}' to #{destination_container.id}"
        log_debug `eval \`ssh-agent\`; ssh-add #{rsync_keyfile}; ssh -o StrictHostKeyChecking=no -A root@#{source_container.get_ip_address} "rsync -aAX -e 'ssh -o StrictHostKeyChecking=no' --include '.httpd.d/' --include '.httpd.d/#{gear.uuid}_***' --include '#{gear.name}-#{app.domain.namespace}' --include '.last_access/' --include '.last_access/#{gear.uuid}' --exclude '*' /var/lib/openshift/ root@#{destination_container.get_ip_address}:/var/lib/openshift/"; exit_code=$?; ssh-agent -k; exit $exit_code`
        if $?.exitstatus != 0
          raise OpenShift::NodeException.new("Error moving system components for app '#{app.name}', gear '#{gear.name}' from #{source_container.id} to #{destination_container.id}", 143)
        end

        # Transfer the front-end configuration to the new gear
        backup = source_container.frontend_backup(gear)
        reply.append destination_container.frontend_restore(backup)
        reply
      end

      #
      # get the status of an application
      #
      # INPUT:
      # app: an Application object
      # 
      # RETURN:
      # * Array: [idle, leave_stopped, quota_file, quota_blocks]
      #
      # NOTES:
      # * calls get_cart_status
      # * method on app or gear?
      # * just a shortcut?
      #
      def get_app_status(app)
        web_framework = nil
        app.requires.each do |feature|
          cart = CartridgeCache.find_cartridge(feature)
          next unless cart.categories.include? "web_framework"
          web_framework = cart.name
          break
        end

        component_instances = app.get_components_for_feature(web_framework)
        gear = component_instances.first.group_instance.gears.first 
        get_cart_status(gear, component_instances.first)
      end

      # 
      # get the status of a cartridge in a gear?
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart_name: String
      #
      # RETURNS:
      # * Array: [idle, leave_stopped, quota_file, quota_blocks]
      #
      # NOTES:
      # * uses do_with_retry
      #
      def get_cart_status(gear, component)
        app = gear.app
        source_container = gear.get_proxy
        leave_stopped = false
        idle = false
        quota_blocks = nil
        quota_files = nil
        log_debug "DEBUG: Getting existing app '#{app.name}' status before moving"
        do_with_retry('status') do
          result = source_container.status(gear, component)
          result.properties["attributes"][gear.uuid].each do |key, value|
            if key == 'status'
              case value
              when "ALREADY_STOPPED"
                leave_stopped = true
              when "ALREADY_IDLED"
                leave_stopped = true
                idle = true
              end
            elsif key == 'quota_blocks'
              quota_blocks = value
            elsif key == 'quota_files'
              quota_files = value
            end
          end
        end

        cart_name = component.cartridge_name
        if idle
          log_debug "DEBUG: Gear component '#{cart_name}' was idle"
        elsif leave_stopped
          log_debug "DEBUG: Gear component '#{cart_name}' was stopped"
        else
          log_debug "DEBUG: Gear component '#{cart_name}' was running"
        end

        return [idle, leave_stopped, quota_blocks, quota_files]
      end

      #
      # Execute an RPC call for the specified agent.
      # If a server is supplied, only execute for that server.
      #
      # INPUTS:
      # * agent: ??
      # * servers: String|Array
      # * force_rediscovery: Boolean
      # * options: Hash
      #
      # RETURNS:
      # * ResultIO
      #
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES:
      # * connects, makes a request, closes connection.
      # * uses MCollective::RPC::Client
      # * THIS IS THE MEAT!
      #
      def self.rpc_exec(agent, servers=nil, force_rediscovery=false, options=rpc_options)

        if servers
          servers = Array(servers)
        else
          servers = []
        end

        # Setup the rpc client
        rpc_client = MCollectiveApplicationContainerProxy.get_rpc_client(agent, options)

        if !servers.empty?
          Rails.logger.debug("DEBUG: rpc_exec: Filtering rpc_exec to servers #{servers.pretty_inspect}")
          rpc_client.discover :nodes => servers
        end

        # Filter to the specified server
        #if server
        #  Rails.logger.debug("DEBUG: rpc_exec: Filtering rpc_exec to server #{server}")
        #  rpc_client.identity_filter(server)
        #end

        if force_rediscovery
          rpc_client.reset
        end
        Rails.logger.debug("DEBUG: rpc_exec: rpc_client=#{rpc_client}")
      
        # Execute a block and make sure we disconnect the client
        begin
          result = yield rpc_client
        ensure
          rpc_client.disconnect
        end

        raise OpenShift::NodeException.new("Node execution failure (error getting result from node).  If the problem persists please contact Red Hat support.", 143) unless result

        result
      end
      
      #
      # Set the district of a node
      #
      # INPUTS:
      # * uuid: String
      # * active: String (?)
      #
      # RETURNS:
      # * ResultIO?
      # 
      # NOTES:
      # * uses MCollective::RPC::Client
      # * uses ApplicationContainerProxy @id
      #
      def set_district(uuid, active)
        mc_args = { :uuid => uuid,
                    :active => active}
        options = MCollectiveApplicationContainerProxy.rpc_options
        rpc_client = MCollectiveApplicationContainerProxy.get_rpc_client('openshift', options)
        result = nil
        begin
          Rails.logger.debug "DEBUG: rpc_client.custom_request('set_district', #{mc_args.inspect}, #{@id}, {'identity' => #{@id}})"
          result = rpc_client.custom_request('set_district', mc_args, @id, {'identity' => @id})
          Rails.logger.debug "DEBUG: #{result.inspect}"
        ensure
          rpc_client.disconnect
        end
        Rails.logger.debug result.inspect
        result
      end
      
      protected
      
      #
      # Try some action until it passes or exceeds a maximum number of tries
      #
      # INPUTS:
      # * action: Block: a code block or method with no arguments
      # * num_tries: Integer
      #
      # RETURNS:
      # * unknown: the result of the action
      #
      # RAISES:
      # * Exception
      #
      # CATCHES:
      # * Exception
      #
      # NOTES:
      # * uses log_debug
      # * just loops retrys
      #
      def do_with_retry(action, num_tries=2)
        (1..num_tries).each do |i|
          begin
            yield
            if (i > 1)
              log_debug "DEBUG: Action '#{action}' succeeded on try #{i}.  You can ignore previous error messages or following mcollective debug related to '#{action}'"
            end
            break
          rescue Exception => e
            log_debug "DEBUG: Error performing #{action} on existing app on try #{i}: #{e.message}"
            raise if i == num_tries
          end
        end
      end
      
      #
      # Initializes the list of cartridges which are "standalone" or framework
      # 
      # INPUTS:
      #
      # RETURNS:
      # * Array of String
      #
      # SIDE EFFECTS:
      # * initialize @framework_carts
      #
      # NOTES:
      # * uses CartridgeCache
      # * why not just ask the CartidgeCache?
      # * that is: Why use an instance var at all?
      #
      def framework_carts(app=nil)
        @framework_carts ||= CartridgeCache.cartridge_names('web_framework', app)
      end

      #
      # Initializes the list of cartridges which are "standalone" or framework
      # 
      # INPUTS:
      #
      # RETURNS:
      # * Array of String
      #
      # SIDE EFFECTS:
      # * initialize @embedded_carts
      #
      # NOTES:
      # * Uses CartridgeCache
      # * Why not just ask the CartridgeCache every time?
      #      
      def embedded_carts(app=nil)
        @embedded_carts ||= CartridgeCache.cartridge_names('embedded',app)
      end
      
      # 
      # Add a component to an existing gear on the node
      #
      # INPUTS:
      # * gear: a Gear object
      # * cart: string representing cartridge name
      #
      # RETURNS:
      # * Array [ResultIO, String]
      #
      # RAISES:
      # * Exception
      #
      # CATCHES:
      # * Exception
      #
      # NOTES:
      # * uses run_cartridge_command
      # * runs "configure" on a "component" which used to be called "embedded"
      #
      def add_component(gear, cart, args)
        app = gear.app
        reply = ResultIO.new

        begin
          reply.append run_cartridge_command(cart, gear, 'configure', args)
        rescue Exception => e
          begin
            Rails.logger.debug "DEBUG: Failed to embed '#{cart}' in '#{app.name}' for user '#{app.domain.owner.login}'"
            reply.debugIO << "Failed to embed '#{cart} in '#{app.name}'"
            reply.append run_cartridge_command(cart, gear, 'deconfigure', args)
          ensure
            raise
          end
        end
        
        component_details = reply.appInfoIO.string.empty? ? '' : reply.appInfoIO.string
        reply.debugIO << "Embedded app details: #{component_details}"
        [reply, component_details]
      end

      # 
      # Post configure a component on the gear
      #
      # INPUTS:
      # * gear: a Gear object
      # * component: String
      #
      # RETURNS:
      # * Array [ResultIO, String]
      #
      # RAISES:
      # * Exception
      #
      # CATCHES:
      # * Exception
      #
      # NOTES:
      # * uses run_cartridge_command
      # * runs "post-configure" on a "component" which used to be called "embedded"
      #
      def post_configure_component(gear, component)
        app = gear.app
        reply = ResultIO.new
        cart = component.cartridge_name

        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        
        begin
          reply.append run_cartridge_command(cart, gear, 'post-configure', args)
        rescue Exception => e
          begin
            Rails.logger.debug "DEBUG: Failed to run post-configure on '#{cart}' in '#{app.name}' for user '#{app.domain.owner.login}'"
            reply.debugIO << "Failed to run post-configure on '#{cart} in '#{app.name}'"
          ensure
            raise
          end
        end
        
        component_details = reply.appInfoIO.string.empty? ? '' : reply.appInfoIO.string
        reply.debugIO << "Embedded app details: #{component_details}"
        [reply, component_details]
      end

      #
      # Remove a component from a gear
      # 
      # INPUTS:
      # * gear: a Gear object
      # * component: String: a component name
      #
      # RETURNS:
      # * ResultIO? String? 
      # 
      # NOTES
      # * method on gear?
      # 
      def remove_component(gear, component)
        app = gear.app
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        cart = component.cartridge_name

        Rails.logger.debug "DEBUG: Deconfiguring embedded application '#{cart}' in application '#{app.name}' on node '#{@id}'"
        return run_cartridge_command(cart, gear, 'deconfigure', args)
      end

      #
      # Start a component service
      # 
      # INPUTS:
      # * gear: a Gear object
      # * component: String: a component name
      #
      # RETURNS:
      # * ResultIO?
      # 
      # NOTES
      # * method on gear?
      #       
      def start_component(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        cart = component.cartridge_name

        run_cartridge_command(cart, gear, "start", args)
      end

      #
      # Stop a component service
      # 
      # INPUTS:
      # * gear: a Gear object
      # * component: String: a component name
      #
      # RETURNS:
      # * ResultIO?
      # 
      # NOTES
      # * method on gear?
      #             
      def stop_component(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        cart = component.cartridge_name

        run_cartridge_command(cart, gear, "stop", args)
      end

      #
      # Restart a component service
      # 
      # INPUTS:
      # * gear: a Gear object
      # * component: String: a component name
      #
      # RETURNS:
      # * ResultIO?
      # 
      # NOTES
      # * method on gear?
      #                   
      def restart_component(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        cart = component.cartridge_name

        run_cartridge_command(cart, gear, "restart", args)
      end
      
      #
      # Reload a component service
      # 
      # INPUTS:
      # * gear: a Gear object
      # * component: String: a component name
      #
      # RETURNS:
      # * ResultIO?
      # 
      # NOTES
      # * method on gear?
      #                   
      def reload_component(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        cart = component.cartridge_name

        run_cartridge_command(cart, gear, "reload", args)
      end

      #
      # Get the status a component service
      # 
      # INPUTS:
      # * gear: a Gear object
      # * component: String: a component name
      #
      # RETURNS:
      # * ResultIO?
      # 
      # NOTES
      # * method on gear?
      #                         
      def component_status(gear, component)
        args = build_base_gear_args(gear)
        args = build_base_component_args(component, args)
        cart = component.cartridge_name

        run_cartridge_command(cart, gear, "status", args)
      end

      #
      # Wrap the log messages so it doesn't HAVE to be rails
      #
      # INPUTS:
      # * message: String
      #
      def log_debug(message)
        Rails.logger.debug message
        puts message
      end

      #
      # Wrap the log messages so it doesn't HAVE to be rails
      #
      # INPUTS:
      # * message: String
      #      
      def log_error(message)
        Rails.logger.error message
        puts message
      end

      # 
      # 
      # INPUTS:
      # * cartridge: String, a cartridge name
      # * action: String, and action name
      # * args: Hash: command arguments
      # * long_debug_output: Boolean
      #
      # RETURNS:
      # * 
      #
      # NOTES:
      # * "cartridge_do" is a catch-all agent message handler
      # * the real switches are the cartridge and action arguments
      # * uses MCollective::RPC::Client
      #
      def execute_direct(cartridge, action, args, log_debug_output=true)
        if not args.has_key?('--cart-name')
          args['--cart-name'] = cartridge
        end

        mc_args = { :cartridge => cartridge,
                    :action => action,
                    :args => args }

        start_time = Time.now
        options = MCollectiveApplicationContainerProxy.rpc_options
        rpc_client = MCollectiveApplicationContainerProxy.get_rpc_client('openshift', options)
        result = nil
        begin
          Rails.logger.debug "DEBUG: rpc_client.custom_request('cartridge_do', #{mc_args.inspect}, #{@id}, {'identity' => #{@id}}) (Request ID: #{Thread.current[:user_action_log_uuid]})"
          result = rpc_client.custom_request('cartridge_do', mc_args, @id, {'identity' => @id})
          Rails.logger.debug "DEBUG: #{result.inspect} (Request ID: #{Thread.current[:user_action_log_uuid]})" if log_debug_output
        rescue => e
          Rails.logger.error("Error processing custom_request for action #{action}: #{e.message}")
          Rails.logger.error(e.backtrace)
        ensure
          rpc_client.disconnect
        end
        Rails.logger.debug "DEBUG: MCollective Response Time (execute_direct: #{action}): #{Time.new - start_time}s  (Request ID: #{Thread.current[:user_action_log_uuid]})" if log_debug_output
        result
      end

      #
      # Cull wanted information out of an MCollective::Reply object
      # INPUTS:
      # * mcoll_reply: MCollective::RPC::Reply
      # * gear: A Gear object
      # * command: String
      #
      # RETURNS:
      # * Object: (Sanitized Result)
      #
      # RAISES:
      # * OpenShift::InvalidNodeException
      # * OpenShift::NodeException
      # * OpenShift::UserException
      #
      # NOTES:
      # * uses find_app
      # * uses sanitize_result
      #
      def parse_result(mcoll_reply, gear=nil, command=nil)
        app = gear.app unless gear.nil?
        result = ResultIO.new
        
        mcoll_result = mcoll_reply[0]
        output = nil
        if (mcoll_result && (defined? mcoll_result.results) && !mcoll_result.results[:data].nil?)
          output = mcoll_result.results[:data][:output]
          result.exitcode = mcoll_result.results[:data][:exitcode]
        else
          server_identity = app ? MCollectiveApplicationContainerProxy.find_app(app.uuid, app.name) : nil
          if server_identity && @id != server_identity
            raise OpenShift::InvalidNodeException.new("Node execution failure (invalid  node).  If the problem persists please contact Red Hat support.", 143, nil, server_identity)
          else
            raise OpenShift::NodeException.new("Node execution failure (error getting result from node).  If the problem persists please contact Red Hat support.", 143)
          end
        end

        gear_id = gear.nil? ? nil : gear.uuid
        result.parse_output(output, gear_id)

        # raise an exception in case of non-zero exit code from the node
        if result.exitcode != 0
          result.debugIO << "Command return code: " + result.exitcode.to_s
          if result.hasUserActionableError
            raise OpenShift::UserException.new(result.errorIO.string, result.exitcode, nil, result)
          else
            raise OpenShift::NodeException.new("Node execution failure (invalid exit code from node).  If the problem persists please contact Red Hat support.", 143, result)
          end
        end
        
        result
      end
      
      #
      # Returns the server identity of the specified app
      #
      # INPUTS:
      # * app_uuid: String
      # * app_name: String
      # 
      # RETURNS:
      # * server identity (string?)
      #
      # NOTES:
      # * uses rpc_exec
      # * loops over all nodes
      #
      def self.find_app(app_uuid, app_name)
        server_identity = nil
        rpc_exec('openshift') do |client|
          client.has_app(:uuid => app_uuid,
                         :application => app_name) do |response|
            output = response[:body][:data][:output]
            if output == true
              server_identity = response[:senderid]
            end
          end
        end
        return server_identity
      end
      
      #
      # Returns whether this server has the specified app
      #
      # INPUTS:
      # * app_uuid: String
      # * app_name: String
      #
      # RETURNS:
      # * Boolean
      #
      # NOTES:
      # * uses rpc_exec
      # * loops over all nodes
      #
      def has_app?(app_uuid, app_name)
        MCollectiveApplicationContainerProxy.rpc_exec('openshift', @id) do |client|
          client.has_app(:uuid => app_uuid,
                         :application => app_name) do |response|
            output = response[:body][:data][:output]
            return output == true
          end
        end
      end
      
      #
      # Returns whether this server has the specified embedded app
      #
      # INPUTS:
      # * app_uuid: String
      # * embedded_type: String
      #
      # RETURNS:
      # * Boolean
      # 
      # NOTES:
      # * uses rpc_exec
      #
      def has_embedded_app?(app_uuid, embedded_type)
        MCollectiveApplicationContainerProxy.rpc_exec('openshift', @id) do |client|
          client.has_embedded_app(:uuid => app_uuid,
                                  :embedded_type => embedded_type) do |response|
            output = response[:body][:data][:output]
            return output == true
          end
        end
      end
      
      #
      # Returns whether this server has already reserved the specified uid as a uid or gid
      #
      # INPUTS:
      # * uid: Integer
      # 
      # RETURNS:
      # * Boolean
      # 
      # NOTES:
      # * uses rpc_exec
      #
      def has_uid_or_gid?(uid)
        return false if uid.nil?
        MCollectiveApplicationContainerProxy.rpc_exec('openshift', @id) do |client|
          client.has_uid_or_gid(:uid => uid.to_s) do |response|
            output = response[:body][:data][:output]
            return output == true
          end
        end
      end

      # This method wraps run_cartridge_command to acknowledge and consistently support the behavior
      # until cartridges and components are handled as distinct concepts within the runtime.
      #
      # If the cart specified is in the framework_carts or embedded_carts list, the arguments will pass
      # through to run_cartridge_command. Otherwise, a new ResultIO will be returned.
      def run_cartridge_command_ignore_components(cart, gear, command, arguments, allow_move=true)       
        if framework_carts(gear.app).include?(cart) || embedded_carts(gear.app).include?(cart)
          result = run_cartridge_command(cart, gear, command, arguments, allow_move)
        else
          result = ResultIO.new
        end
        result
      end

      #
      # Execute a cartridge hook command in a gear
      #
      # INPUTS:
      # * framework:
      # * gear: a Gear object
      # * command: the hook command to run on the node?
      # * arg: ??
      # * allow_move: Boolean
      #
      # RETURNS:
      # * ResultIO
      # 
      # RAISES:
      # * Exception
      #
      # CATCHES:
      # * OpenShift::InvalidNodeException
      #
      # NOTES:
      # * uses execute_direct
      #
      def run_cartridge_command(framework, gear, command, arguments, allow_move=true)
        app = gear.app
        resultIO = nil

        result = execute_direct(framework, command, arguments)

        begin
          begin
            resultIO = parse_result(result, gear, command)
          rescue OpenShift::InvalidNodeException => e
            if command != 'configure' && allow_move
              @id = e.server_identity
              Rails.logger.debug "DEBUG: Changing server identity of '#{gear.name}' from '#{gear.server_identity}' to '#{@id}'"
              dns_service = OpenShift::DnsService.instance
              dns_service.modify_application(gear.name, app.domain.namespace, get_public_hostname)
              dns_service.publish
              gear.server_identity = @id
              app.save
              #retry
              result = execute_direct(framework, command, arguments)
              resultIO = parse_result(result, gear, command)
            else
              raise
            end
          end
	      rescue OpenShift::NodeException => e
          if command == 'deconfigure'
            if framework.start_with?('embedded/')
              if has_embedded_app?(app.uuid, framework[9..-1])
                raise
              else
                Rails.logger.debug "DEBUG: Component '#{framework}' in application '#{app.name}' not found on node '#{@id}'.  Continuing with deconfigure."
                resultIO = ResultIO.new
              end
            else
              if has_app?(app.uuid, app.name)
                raise
              else
                Rails.logger.debug "DEBUG: Application '#{app.name}' not found on node '#{@id}'.  Continuing with deconfigure."
                resultIO = ResultIO.new
              end
            end
          else
            raise
          end
        end

        resultIO
      end
      
      #
      # Execute a cartridge hook command in a gear
      #
      # INPUTS:
      # * force_rediscovery: Boolean
      # * rpc_opts: Hash
      #
      # RETURNS:
      # * Array of known server identities
      # 
      # RAISES:
      # * Exception
      #
      def self.known_server_identities(force_rediscovery=false, rpc_opts=nil)
        server_identities = nil
        server_identities = Rails.cache.read('known_server_identities') unless force_rediscovery
        unless server_identities
          server_identities = []
          rpc_get_fact('active_capacity', nil, true, force_rediscovery, nil, rpc_opts) do |server, capacity|
            #Rails.logger.debug "Next server: #{server} active capacity: #{capacity}"
            server_identities << server
          end
          Rails.cache.write('known_server_identities', server_identities, {:expires_in => 1.hour}) unless server_identities.empty?
        end
        server_identities
      end

      #
      # ???
      #
      # INPUTS:
      # * node_profile: String identifier for a set of node characteristics
      # * district_uuid: String identifier for the district
      # * least_preferred_server_identities: list of server identities that are least preferred. These could be the ones that won't allow the gear group to be highly available
      # * force_rediscovery: Boolean
      # * gear_exists_in_district: Boolean - true if the gear belongs to a node in the same district  
      # * required_uid: String - the uid that is required to be available in the destination district
      #
      # RETURNS:
      # * Array: [server, capacity, district] 
      # 
      # NOTES:
      # * are the return values String?
      #
      # VALIDATIONS:
      # * If gear_exists_in_district is true, then required_uid cannot be set and has to be nil
      # * If gear_exists_in_district is true, then district_uuid must be passed and cannot be nil
      #
      def self.rpc_find_available(node_profile=nil, district_uuid=nil, least_preferred_server_identities=nil, force_rediscovery=false, gear_exists_in_district=false, required_uid=nil)

        district_uuid = nil if district_uuid == 'NONE'
        
        # validate to ensure incompatible parameters are not passed
        if gear_exists_in_district
          if required_uid or district_uuid.nil?
            raise OpenShift::UserException.new("Incompatible parameters being passed for finding available node within the same district", 1)
          end
        end

        require_specific_district = !district_uuid.nil?
        require_district = require_specific_district
        prefer_district = require_specific_district
        unless require_specific_district
          if Rails.configuration.msg_broker[:districts][:enabled] && (!district_uuid || district_uuid == 'NONE')
            prefer_district = true
            if Rails.configuration.msg_broker[:districts][:require_for_app_create]
              require_district = true
            end
          end
        end
        require_district = true if required_uid
        current_server, current_capacity = nil, nil
        server_infos = []

        # First find the most available nodes and match 
        # to their districts.  Take out the almost full nodes if possible and return one of 
        # the nodes within a district with a lot of space. 
        additional_filters = [{:fact => "active_capacity",
                               :value => '100',
                               :operator => "<"}]
        
        if require_specific_district || require_district
          additional_filters.push({:fact => "district_active",
                                   :value => true.to_s,
                                   :operator => "=="})
        end
                               
        if require_specific_district
          additional_filters.push({:fact => "district_uuid",
                                   :value => district_uuid,
                                   :operator => "=="})                         
        elsif require_district
          additional_filters.push({:fact => "district_uuid",
                                   :value => "NONE",
                                   :operator => "!="})
        elsif !prefer_district
          additional_filters.push({:fact => "district_uuid",
                                   :value => "NONE",
                                   :operator => "=="})
        end

        if node_profile && Rails.configuration.msg_broker[:node_profile_enabled]
          additional_filters.push({:fact => "node_profile",
                                   :value => node_profile,
                                   :operator => "=="})
        end

        # Get the districts
        districts = prefer_district ? District.find_all : [] # candidate for caching
          
        # Get the active % on the nodes
        rpc_opts = nil
        rpc_get_fact('active_capacity', nil, force_rediscovery, additional_filters, rpc_opts) do |server, capacity|
          found_district = false
          districts.each do |district|
            if district.server_identities_hash.has_key?(server)
              next if required_uid and !district.available_uids.include?(required_uid)
              if (gear_exists_in_district || district.available_capacity > 0) && district.server_identities_hash[server]["active"] 
                server_infos << [server, capacity.to_f, district]
              end
              found_district = true
              break
            end
          end
          if !found_district && !require_district # Districts aren't required in this case
            server_infos << [server, capacity.to_f]
          end
        end
        if require_district && server_infos.empty?
          raise OpenShift::NodeException.new("No district nodes available.", 140)
        end
        unless server_infos.empty?
          # Remove the least preferred servers from the list, ensuring there is at least one server remaining
          server_infos.delete_if { |server_info| server_infos.length > 1 && least_preferred_server_identities.include?(server_info[0]) } if least_preferred_server_identities

          # Remove any non districted nodes if you prefer districts
          if prefer_district && !require_district && !districts.empty?
            has_districted_node = false
            server_infos.each do |server_info|
              if server_info[2]
                has_districted_node = true
                break
              end
            end
            server_infos.delete_if { |server_info| !server_info[2] } if has_districted_node
          end

          # Sort by node available capacity and take the best half
          server_infos = server_infos.sort_by { |server_info| server_info[1] }
          server_infos = server_infos.first([4, (server_infos.length / 2).to_i].max) # consider the top half and no less than min(4, the actual number of available)

          # Sort by district available capacity and take the best half
          server_infos = server_infos.sort_by { |server_info| (server_info[2] && server_info[2].available_capacity) ? server_info[2].available_capacity : 1 }
          server_infos = server_infos.last([4, (server_infos.length / 2).to_i].max) # consider the top half and no less than min(4, the actual number of available)
        end

        current_district = nil
        unless server_infos.empty?
          # Randomly pick one of the best options
          server_info = server_infos[rand(server_infos.length)]
          current_server = server_info[0]
          current_capacity = server_info[1]
          current_district = server_info[2]
          Rails.logger.debug "Current server: #{current_server} active capacity: #{current_capacity}"
        end

        return current_server, current_capacity, current_district
      end
      
      #
      # Return a single node matching a given profile
      #
      # INPUTS:
      # * node_profile: Object?
      #
      # RETURNS:
      # * String: server name?
      # 
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES:
      # * Query facters from every node and filter on server side
      # * uses MCollective::RPC::Client
      #
      def self.rpc_find_one(node_profile=nil)
        current_server = nil
        additional_filters = []

        if Rails.configuration.msg_broker[:node_profile_enabled]
          if node_profile
            additional_filters.push({:fact => "node_profile",
                                     :value => node_profile,
                                     :operator => "=="})
          end
        end

        options = MCollectiveApplicationContainerProxy.rpc_options
        options[:filter]['fact'] = options[:filter]['fact'] + additional_filters
        options[:mcollective_limit_targets] = "1"

        rpc_client = MCollectiveApplicationContainerProxy.get_rpc_client('rpcutil', options)
        begin
          rpc_client.get_fact(:fact => 'public_hostname') do |response|
            raise OpenShift::NodeException.new("No nodes found.  If the problem persists please contact Red Hat support.", 140) unless Integer(response[:body][:statuscode]) == 0
            current_server = response[:senderid]
          end
        ensure
          rpc_client.disconnect
        end
        return current_server
      end
      
      #
      # Make a deep copy of the RPC options hash
      #
      # INPUTS:
      #
      # RETURNS:
      # * Object
      #
      # NOTES:
      # * Simple copy by Marshall load/dump
      #
      def self.rpc_options
        # Make a deep copy of the default options
        Marshal::load(Marshal::dump(Rails.configuration.msg_broker[:rpc_options]))
      end
    
      #
      # Return the value of the MCollective response
      # for both a single result and a multiple result
      # structure
      #
      # INPUTS:
      # * response: an MCollective::Response object
      #
      # RETURNS:
      # * String: value string
      #
      # NOTES:
      # * returns value from body or data
      # 
      def self.rvalue(response)
        result = nil
    
        if response[:body]
          result = response[:body][:data][:value]
        elsif response[:data]
          result = response[:data][:value]
        end
    
        result
      end
    
      # 
      # true if the response indicates success
      #
      # INPUTS:
      # * response
      # 
      # RETURNS:
      # * Boolean
      #
      # NOTES:
      # * method on custom response object?
      #
      def rsuccess(response)
        response[:body][:statuscode].to_i == 0
      end
    
      #
      # Returns the fact value from the specified server.
      # Yields to the supplied block if there is a non-nil
      # value for the fact.
      # 
      # INPUTS:
      # * fact: String - a fact name
      # * servers: String|Array - a node name or an array of node names
      # * force_rediscovery: Boolean
      # * additional_filters: ?
      # * custom_rpmc_opts: Hash?
      #
      # RETURNS:
      # * String?
      #
      # NOTES:
      # * uses rpc_exec
      # 

      def self.rpc_get_fact(fact, servers=nil, force_rediscovery=false, additional_filters=nil, custom_rpc_opts=nil)
        result = nil
        options = custom_rpc_opts ? custom_rpc_opts : MCollectiveApplicationContainerProxy.rpc_options
        options[:filter]['fact'] = options[:filter]['fact'] + additional_filters if additional_filters

        Rails.logger.debug("DEBUG: rpc_get_fact: fact=#{fact}")
        rpc_exec('rpcutil', servers, force_rediscovery, options) do |client|
          client.get_fact(:fact => fact) do |response|
            next unless Integer(response[:body][:statuscode]) == 0
    
            # Yield the sender and the value to the block
            result = rvalue(response)
            yield response[:senderid], result if result
          end
        end

        result
      end
    
      #
      # Given a known fact and node, get a single fact directly.
      # This is significantly faster then the get_facts method
      # If multiple nodes of the same name exist, it will pick just one
      #
      # INPUTS:
      # * fact: String
      #
      # RETURNS:
      # * String
      #
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES
      # * uses MCollectiveApplicationContainerProxxy.rpc_options
      # * uses MCollective::RPC::Client
      # 
      def rpc_get_fact_direct(fact)
          options = MCollectiveApplicationContainerProxy.rpc_options
    
          rpc_client = MCollectiveApplicationContainerProxy.get_rpc_client('rpcutil', options)
          begin
            result = rpc_client.custom_request('get_fact', {:fact => fact}, @id, {'identity' => @id})[0]
            if (result && defined? result.results && result.results.has_key?(:data))
              value = result.results[:data][:value]
            else
              raise OpenShift::NodeException.new("Node execution failure (error getting fact).  If the problem persists please contact Red Hat support.", 143)
            end
          ensure
            rpc_client.disconnect
          end
    
          return value
      end
    
      #
      # Get mcollective rpc client. For errors, convert generic exception
      # to NodeException.
      #
      # INPUTS:
      # * agent: String (??)
      # * options: Hash
      # 
      # RETURNS:
      # * MCollective::RPC::Client
      #
      # RAISES:
      # * OpenShift::NodeException
      #
      # NOTES
      # * Uses MCollective::RPC::Client
      #
      def self.get_rpc_client(agent, options)
          flags = { :options => options, :exit_on_failure => false }

          begin
            rpc_client = rpcclient(agent, flags)
          rescue Exception => e
            raise OpenShift::NodeException.new(e)
      end

          return rpc_client
      end

      #
      # Retrieve all gear IDs from all nodes (implementation)
      #
      # INPUTS:
      # * none
      # 
      # RETURNS:
      # * Hash [gear_map[], node_map[]]
      #
      # NOTES:
      # * Should be class method on Node? (All nodes?)
      # * Why doesn't this just override a method from the superclass?
      # * uses rpc_exec
      #
      def self.get_all_gears_impl(opts)
        gear_map = {}
        sender_map = {}
        rpc_exec('openshift', nil, true) do |client|
          client.get_all_gears(opts) do |response|
            if response[:body][:statuscode] == 0
              sub_gear_map = response[:body][:data][:output]
              sender = response[:senderid]
              sub_gear_map.each { |k,v|
                gear_map[k] = [sender,Integer(v)]
                sender_map[sender] = {} if not sender_map.has_key? sender
                sender_map[sender][Integer(v)] = k
              }
            end
          end
        end
        return [gear_map, sender_map]
      end

      #
      # Retrieve all active gears (implementation)
      #
      # INPUTS:
      # * none
      #
      # RETURNS:
      # * Hash: active_gears_map[nodekey]
      #
      # NOTES:
      # * should be class method on Node? or Broker?
      # * uses MCollective::RPC::Client rpc_exec
      # * uses MCollective::RPC::Client.missing_method ??
      #
      def self.get_all_active_gears_impl
        active_gears_map = {}
        rpc_exec('openshift', nil, true) do |client|
          client.get_all_active_gears() do |response|
            if response[:body][:statuscode] == 0
              active_gears = response[:body][:data][:output]
              sender = response[:senderid]
              active_gears_map[sender] = active_gears
            end
          end
        end
        active_gears_map
      end

      #
      # Retrieve all ssh keys for all gears from all nodes (implementation)
      #
      # INPUTS:
      # * none
      # 
      # RETURNS:
      # * Hash [gear_sshey_map[], node_list[]]
      #
      # NOTES:
      # * Should be class method on Node? (All nodes?)
      # * Why doesn't this just override a method from the superclass?
      # * uses rpc_exec
      #
      def self.get_all_gears_sshkeys_impl
        gear_sshkey_map = {}
        sender_list = []
        rpc_exec('openshift', nil, true) do |client|
          client.get_all_gears_sshkeys do |response|
            if response[:body][:statuscode] == 0
              gear_sshkey_map.merge! response[:body][:data][:output]
              sender_list.push response[:senderid]
            end
          end
        end
        return [gear_sshkey_map, sender_list]
      end

      #
      # <<implementation>>
      # <<class method>>
      #
      # Execute a set of operations on a node in parallel
      # 
      # INPUTS:
      # * handle: Hash ???
      # 
      # RETURNS:
      # * ???
      #
      # NOTES:
      # * uses MCollectiveApplicationContainerProxy.sanitize_result
      # * uses MCollectiveApplicationContainerProxy.rpc_options
      # * uses MCollective::RPC::Client
      #
      def self.execute_parallel_jobs_impl(handle)
        if handle && !handle.empty?
          start_time = Time.new
          begin
            options = MCollectiveApplicationContainerProxy.rpc_options
            rpc_client = MCollectiveApplicationContainerProxy.get_rpc_client('openshift', options)
            mc_args = handle.clone
            identities = handle.keys
            rpc_client.custom_request('execute_parallel', mc_args, identities, {'identity' => identities}).each { |mcoll_reply|
              if mcoll_reply.results[:statuscode] == 0 
                output = mcoll_reply.results[:data][:output]
                exitcode = mcoll_reply.results[:data][:exitcode]
                sender = mcoll_reply.results[:sender]
                Rails.logger.debug("DEBUG: Output of parallel execute: #{output}, exitcode: #{exitcode}, from: #{sender}  (Request ID: #{Thread.current[:user_action_log_uuid]})")
                
                handle[sender] = output if exitcode == 0
              end
            }
          ensure
            rpc_client.disconnect
          end
          Rails.logger.debug "DEBUG: MCollective Response Time (execute_parallel): #{Time.new - start_time}s  (Request ID: #{Thread.current[:user_action_log_uuid]})"
        end
      end
    end
end
