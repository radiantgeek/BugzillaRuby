# (c) first version, http://rubyforge.org/projects/rubzilla/
#
# (c) refactoring, new functions from Bugzilla 3.4, Dmitry 'radiant' Volkov
#
# See links below for more information:
#   http://www.bugzilla.org/docs/3.6/en/html/api/Bugzilla/WebService/Bug.html
#   http://www.bugzilla.org/docs/3.6/en/html/api/Bugzilla/WebService/Product.html
#   http://www.bugzilla.org/docs/3.6/en/html/api/Bugzilla/WebService/User.html
#
# NB! Supports >= Bugzilla 3.4


require 'xmlrpc/client'
require 'logger'
require 'singleton'
require 'yaml'

# Bugzilla singleton class is used for working with bugzilla
#
# How to use:
#    Bug.create(id) 
#    Bugzilla.search(paramMap)    # Returns a list of search matching search criterias
#      * Examples: bz.search(), bz.search({"last_change_time" => "2010-01-01"}) 
#    Bugzilla.get(ids)            # Returns a list of bugs
#      * Examples: bz.get(1), bz.get([1, 4]) 
#    Bugzilla.comments(bugid)     # Returns a list of comments for specific bug
#      * Examples: bz.comments(1), bz.comments([1,4]), bz.comments({"new_since"=>"2010-01-01"})   
#    Bugzilla.users(params)       # Returns a list of users
#      * Examples: bz.users(23), bz.users([1, 4]), bz.users({"match" => [".org"]}) 
#    Bugzilla.history(bugid)      # Returns a history for specific bug
#      * Examples: bz.history(1), bz.history([1,4])   
#    Bugzilla.attachments(bugid)  # Returns attachments for specific bug
#      * Examples: bz.attachments(1), bz.attachments([1,4]), bz.attachments({"attachment_ids"=>[12,32]})   
#    Bugzilla.fields(params={})   # Returns a fields list, including the lists of legal values for each field
#      * Examples: bz.fields(), bz.fields(1), bz.fields([1, 4]), bz.fields({"names" => ["component", "priority"]}) 
#    Bugzilla.products(id=-1)     # Returns a list of products for specific id [-1, for all]
#      * Examples: bz.products(), bz.products(1), bz.products([1, 4]) 
# For more information please read Bugzilla API Manual
#  
# Classes represents the Bugzilla's entities:   
#   User, Comment, Field, HistoryEntry, Attachment, Product 
#
# Errors:
#  BugInvalid, ItemNotFound < StandardError

module Bugzilla
  
  ## For debugging
  #  Hash.class_eval do
  #    def to_s
  #      "{\n" + join(", \n") { |k, v|
  #          "   " + k.to_s + " => (" + v.class.to_s + ")" + v.to_s
  #      } + "\n}"
  #    end
  #    
  #    def join(delim)
  #      s = ""
  #      each {|k,v| s+=delim if s.length>0; s+= yield(k,v)}
  #      s
  #    end
  #  end
  #  
  #  Array.class_eval do
  #    def to_s
  #      "[" + join(", ")+"]" 
  #    end
  #  end
  
  class Utils
    
    def self.getPath(type)
      if defined?(RAILS_ROOT)
        log_path = File.join(RAILS_ROOT,type)
      else
        log_path = File.join(File.dirname(__FILE__), type)
      end
      log_path
    end
  end
  
  class Bugzilla
    include Singleton
    
    attr_reader :defaults, :base_url
    
    private
    def initialize
      #      Create a logger, keep 5 old logs of 1MB each
      log_file = File.join(Utils.getPath('log'), 'bugzilla.log')      
      @log = Logger.new(log_file,5,1048576)
      
      config_file = File.join(Utils.getPath('config'), 'bugzilla.yml') 
      
      config = YAML::load(IO.read(config_file))['bugzilla']
      unless config
        @log.fatal("Cannot load configuration file.")
        exit(-1)
      end
      
      # Global configuration
      @login = config['login']
      @password = config['password']
      @base_url = config['base_url']
      
      # Flag for Logged in to Bugzilla
      @logged_in = false
      
      # Default bug report configuration
      @defaults=config[:defaults]
      
      @xmlrpc_url = @base_url + '/xmlrpc.cgi'
      @server = XMLRPC::Client.new2(@xmlrpc_url)
    end
    
    public
    
    def create(bug)
      raise 'Bugzilla::Bug expected' unless bug.is_a?(Bug)
      if bug.valid?
        login
        # Don't pass the 'internals' hash to Bugzilla API, it cannot handle it.
        new_bug = bug.dup
        new_bug.delete(:internals)
        bug.id = @server.call('Bug.create', new_bug)['id']
        return bug
      else
        return false
      end
    rescue XMLRPC::FaultException => e
      @log.error("XMLRPC::FaultException: #{e.faultCode} - #{e.faultString}")
      return false
    end
    
    # Returns the Bugzilla version
    def version
      @version ||= @server.call('Bugzilla.version')['version']
    end
    
    # Returns a list of bugs   
    def get(ids)
      getList("Bug.get_bugs", ids, "bugs") { |b| Bug.new(b) }
    end
    
    
    # Returns a list of search matching search criterias
    def search(paramMap={})
      getList("Bug.search", paramMap, "bugs") { |b| Bug.new(b) }
    end
    
    # Returns a list of comments for specific bug
    def comments(bugid)
      getList("Bug.comments", bugid, 'bugs') { |b|
        b['comments'].collect { |c| 
          Comment.new(c) 
        } 
      }
    end
    
    # Returns a list of users
    def users(userid)
      serverCall {
        getList("User.get", userid, 'users') { |u|
          User.new(u) 
        }}
    end
    
    # Returns a history for specific bug
    def history(bugid)
      getList("Bug.history", bugid, 'bugs') { |b|
        b['history'].collect { |h| 
          HistoryEntry.new(h) 
        } 
      }
    end
    
    # Returns attachments for specific bug
    def attachments(bugid)
      getList("Bug.attachments", bugid, 'bugs') { |b|
        # NB! Workaround!
        # According to Bugzilla API 3.6 it must be: b['attachments'].collect
        b.collect { |a| 
          Attachment.new(a) 
        } 
      }
    end
    
    # Returns a fields list
    def fields(params={})
      getList("Bug.fields", params, 'fields') { |f| Field.new(f) }
    end
    
    # Returns a list of products
    def products(id=-1)
      serverCall {
        @products ||= # This action is quite slow and expensive, so we'd rather cache the result
        begin
          #          login
          #          product_ids = @server.call('Product.get_accessible_products')['ids']
          #          product_ids = @server.call('Product.get_accessible_products')['ids']
          product_ids = getList("Product.get_accessible_products", {}, 'ids') { |id| id }          
          getList("Product.get", product_ids, 'products') { |p| Product.new(p) }          
        end
      }
      res = @products
      arr = [id] unless id.is_a?(Array)  
      res = products.find { |p| arr.include?(p.id) } unless id==-1
      res
    end
    
    private
    
    # Logs into Bugzilla using the credentials specified in the configuration file
    def login
      unless @logged_in
        @log.info("Try to login")
        @server.call('User.login', {'login'=>@login, 'password'=>@password, 'remember'=>1})
        # workaround Bugzilla's broken cookies handling was removed
        if @server.cookie =~ /Bugzilla_logincookie=([^;]+)/
          @logged_in = true
        end
      end
    end
    
    def getList(methodName, id, listName)
      serverCall {
        login
        
        # flat params to array
        id = [id] unless id.is_a?(Array) || id.is_a?(Hash)  
        # arrays to map
        id = {:ids => id} unless id.is_a?(Hash)
        
        @log.info("Getting #{methodName} for id #{id}")
        res = @server.call(methodName, id)[listName]
        
        res = res.values if res.is_a?(Hash) 
        res = res.collect { |v| yield v } if res.is_a?(Array) 
        res
      }
    end
    
    def serverCall()
      yield
    rescue XMLRPC::FaultException => e
      @log.error("XMLRPC::FaultException: #{e.faultCode} - #{e.faultString}")
      nil
    end
  end
  
  # Base class for Bugzilla's data hierarchy
  class HashedObject < Hash
    def initialize(hash={})
      new_hash = Hash.new
      hash.each { |k,v| new_hash[k.to_sym] = v }
      self.merge!(new_hash)
      
      @id = self[:id]
    end
    
    def id
      @id
    end
    
    def to_s
      @id.to_s
    end
    
    def method_missing(method_id, *args)
      method_id = method_id.id2name.to_sym
      if method_id.to_s =~ /(.*)=$/
        method_id = $1.to_sym
        self[method_id] = args.first
      else
        self[method_id] if self.has_key?(method_id)
      end
    end
  end
  
  class Bug < HashedObject
    REQUIRED_CREATE_FIELDS = [:bug_severity,:comment,:component,:op_sys,:priority,
                              :product,:rep_platform,:short_desc,:version]
    
    attr_accessor :errors
    
    def initialize(hash={})
      @errors = Errors.new(self)
      @bugzilla = Bugzilla.instance
      new_hash = @bugzilla.defaults.dup
      # Add items from the provided hash to the new one
      if ! hash.empty?
        hash.each_key {|k| new_hash[k.to_sym]= hash[k]}
      end
      self.merge!(new_hash)
      # Move the required fields to the main hash, because this way they're
      # expected to appear when creating a bug
      self[:internals] ||= {}
      unless self[:internals].empty?
        %w{short_desc version}.each do |key|
          self[key.to_sym] = self[:internals].delete(key)
        end
      end
    end
    
    def self.create(options)
      raise "Bug expected" unless options.respond_to?(:keys)
      bug = Bug.new(options) 
      Bugzilla.instance.create(bug)
      bug
    end
    
    def self.create!(options)
      raise "Bug expected" unless options.respond_to?(:keys)
      bug = Bug.new(options)
      res = Bugzilla.instance.create(bug)
      raise BugInvalid.new(bug) unless bug.errors.empty?
      raise "Cannot create, see log" unless res
      bug
    end
    
    def save
      @bugzilla.create(self)
    end
    
    def save!
      res = @bugzilla.create(self)
      raise BugInvalid.new(self) unless self.errors.empty?
      raise "Cannot create, see log #{res.inspect}" unless res
      self
    end
    
    # Return the bug id if it exists in bugzilla, i.e. saved or retrieved. Otherwise, return nil
    def id
      if self[:internals]
        self[:internals]['bug_id']
      else
        nil
      end
    end
    
    def id=(bug_id)
      self[:internals]['bug_id']=bug_id
    end
    
    def last_change_time
      self[:last_change_time] ? self[:last_change_time].to_time : nil
    end
    
    def creation_time
      self[:creation_time] ? self[:creation_time].to_time : nil
    end
    
    def self.content_columns
      REQUIRED_CREATE_FIELDS.collect { |c| BugColumn.new(c) }
    end
    
    def valid?
      self.errors.clear
      missing = Bug::REQUIRED_CREATE_FIELDS - self.keys
      if missing.empty?
        true
      else
        missing.each {|m| self.errors.add(m,'is required')}
        false
      end
    end
    
    # Internal class needed to fake ActiveRecord's content_columns array
    class BugColumn
      attr_reader :name
      
      def initialize(name)
        @name = name.to_s
      end
      
      def human_name
        @name.capitalize
      end
    end
    
  end
  
  # This class represents the Bugzilla's users
  class User < HashedObject
    # id, real_name, email, name, can_login, email_enabled, login_denied_text
    
    def to_s
      real_name.to_s 
    end
  end
  
  # This class represents the Bugzilla's comments
  class Comment < HashedObject
    # id, time, text, bug_id
    
    def to_s
      "[ #" + bug_id.to_s + "[" + id.to_s + ", "+time.to_s+"] " + text + " ]"
    end
  end
  
  
  # This class represents the Bugzilla's fields
  class Field < HashedObject
    # id, name, display_name, type, values
    # ** values: array {name, sortkey(int), is_open(boolean), can_change_to(array {name, comment_required})}
    
    def to_s
      name + "["+values.to_s+"]\n"
    end
  end  
  
  # This class represents the Bugzilla's histories
  class HistoryEntry < HashedObject
    # time, who, changes
    # ** changes: array {field_name, removed, added, attachment_id}    
    attr_reader :time
    
    def initialize(hash={})
      super(hash)
      @time = self[:when]
    end
    
    def to_s
      "[ #" + time.to_s + ", " + who.to_s + ": " + changes.to_s + "\n"
    end
  end
  
  # This class represents the Bugzilla's attachments
  class Attachment < HashedObject
    # id, bug_id, creation_time,last_change_time, file_name, description, content_type, is_private, is_obsolete, is_url, is_patch, attacher
    
    def to_s
      "[ #" + bug_id.to_s + "[" + id.to_s + "] " + description + " ]"
    end
  end
  
  # This class represents the Bugzilla's "products"
  class Product < HashedObject
    attr_accessor :name, :description
    
    # Constructor for the Products class
    def initialize(hash={})
      super(hash)
      @name = self[:name]
      @description = self[:description]
      # NB deprecated??      
      #      @components = self[:components].collect { |c| Component.new(c) }
      #      @versions = self[:versions].collect { |v| Version.new(v) }
    end
    
    
    ### Internal classes    
    # A class which represents Products' components
    class Component < HashedObject
      # description, name
      
    end    
    
    # A class which represents Products' versions
    class Version < HashedObject
      # name
    end
    
  end
  
  
  class Errors
    include Enumerable
    attr_accessor :errors
    
    @@default_error_messages = {
      :invalid => "is invalid",
      :empty => "can't be empty"
    }
    
    def initialize(base)
      @base, @errors = base, {}
    end
    
    def add(attribute, msg = @@default_error_messages[:invalid])
      @errors[attribute.to_sym] = [] if @errors[attribute.to_sym].nil?
      @errors[attribute.to_sym] << msg
    end
    
    def clear
      @errors = {}
    end
    
    def empty?
      @errors.empty?
    end
    
    def each
      @errors.each_key { |attr| @errors[attr].each { |msg| yield attr, msg } }
    end
    
    def length
      @errors.length
    end
    
    def on(key)
      errors = @errors[key.to_sym]
      return nil if errors.nil?
      errors.size == 1 ? errors.first : errors
    end
    
    alias :[] :on
    alias :size :length
    alias :count :length
  end
  
  class BugInvalid < StandardError
    attr_reader :bug
    def initialize(bug)
      @bug = bug
      super
    end
  end
  
  class ItemNotFound < StandardError
  end
  
end