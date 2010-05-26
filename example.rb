# Example module for converting data response from Bugzilla for more human-readable view
#

require 'bugzilla'

module Example  
  class Bug < Hash
    attr_reader :id
    
    def self.serverUrl
      Bugzilla::Bugzilla.instance.base_url
    end

    # get bug or bug lists using our class 
    def self.convert(b)
      return self.new(b)  if b.is_a?(Bugzilla::Bug) 
      
      return b.collect {|bug| self.new(bug) } if b.is_a?(Array)
      
      raise 'Bugzilla::Bug(s) expected' 
    end

    
    def initialize(bug)
      @bug = bug
      
      # get all datas [return from API and internals data]
      @full = Hash.new()
      @bug.internals.each_key {|k| @full[k.to_sym] = @bug.internals[k]}
      @full.merge!(@bug)

  @full.each { |a, b| 
    puts a.to_s+"=>"+b.to_s 
  }
      
      # clear names      
      self[:id] = @id = @full[:bug_id]            
      self[:link] = Bug.serverUrl + "show_bug.cgi?id=" + @id.to_s

      # copy data from API
      copy = [:summary, :status, :resolution, :severity, :priority, :assigned_to, :is_open, :component, :product]
      copy.each { |sym| self[sym] = @full[sym] }

      # copy from internals
      # NB! it's bad practice, but it gives much more information than official API 
      self[:reporter] = @full[:reporter_id]       
      self[:version] = @full[:version]      
      self[:milestone] = @full[:target_milestone]      
      self[:platform] = @full[:rep_platform]      
      self[:os] = @full[:op_sys]                  
      self[:confirmed] = @full[:everconfirmed]   
      self[:estimated_time] = @full[:estimated_time]  
      self[:remaining_time] = @full[:remaining_time] 
      
      # copy from internals
      # It' recommended use official @full[:creation_time], @full[:last_change_time]
      # But there are XMLRPC::DateTime.
      
      self[:created] = @full[:creation_ts]        
      self[:modified] = @full[:delta_ts]          
      
    end
    
    private
  
    # for using "bug.milestone" instead of "bug[:milestone]"
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
end


## Example:
server = Bugzilla::Bugzilla.instance.search({"id" => 804})
converted = Example::Bug.convert(server)
converted.each { |bug|
  bug.each { |a, b| 
    puts a.to_s+"=>"+b.to_s 
  }
} 
