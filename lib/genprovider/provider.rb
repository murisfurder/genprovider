#
# provider.rb
#

class String
  #
  # Convert from CamelCase to under_score
  #
  def decamelize
    self.gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
	 gsub(/([a-z\d])([A-Z])/,'\1_\2').
	 tr("-", "_").
	 downcase
  end
end

require 'cim'

module CIM
  class ReferenceType < Type
    def to_cmpi
      "Cmpi::ref"
    end
  end
  class Type
    def to_cmpi
      t = type
      a = ""
      if array?
	a = "A"
      end
      "Cmpi::#{t}#{a}"
    end
  end
  class ClassFeature
    def method_missing name
      qualifiers[name]
    end
  end
  class Qualifier
    def method_missing name, *args
      if name == :"[]"
	value[*args]
      else
	super name, *args
      end
    end
  end
end


module Genprovider
  class Provider
    #
    # iterate features
    # **internal**
    #  predicate: feature predicate symbol, like :property?
    #  filter:    :keys   # keys only
    #             :nokeys # non-keys only
    #             :all    # all
    #
    # yields { |feature, klass| } if block_given?
    # returns Array of [feature,klass] pairs else
    #
    def features predicate, filter
      result = nil
      #
      # We start to iterate features from the child class and
      # climb up the parent chain
      #   overrides = { name => features }
      # collects information about overridden features along
      # the parent chain
      overrides = {}
      
      # climb up parent chain
      klass = @klass
      while klass
	klass.features.each do |feature|
	  next unless feature.send(predicate)

          # overriden in child class ?
	  f_override = overrides[feature.name]
	  if f_override # Y: f_override = overriding feature
	    # copy qualifiers from overridden to overriding feature
	    feature.qualifiers.each do |q|
	      unless f_override.qualifiers[q.name] # non-overridden qualifier
		f_override.qualifiers << q
	      end
	    end
	    next # skip this feature
	  end

          # does this feature override a parent feature ?
          overrides[feature.name] = feature if feature.override

	  if feature.key?
	    next if filter == :nokeys
	  else
	    next if filter == :keys
	  end
          if block_given?
            yield feature, klass
          else
            result ||= Array.new
            result << [feature,klass]
          end
	end
        klass = klass.parent
      end
      result
    end

    # iterate properties
    #  filter:    :keys   # keys only
    #             :nokeys # non-keys only
    #             :all    # all
    #
    # accepts optional block
    #
    def properties filter, &block
      features :property?, filter, &block
    end

    # iterate methods
    #
    # accepts optional block
    #
    def methods &block
      features :method?, :all, &block
    end

    LOG = "@trace_file.puts" # "@log.info"
    
    #
    # Find bounds for property values
    #
    #  Usage:
    #      bounds property, :MaxLen, :Max, :Min
    #
    def bounds property, *args
      s = ""
      args.each do |n|
	v = property.send(n)
	s << "#{n} #{v} " if v
      end
      s
    end

    #
    # Return reasonable default for type
    #
    def default_for_type type
      if type.array? then "[]"
      elsif type == :boolean then "false"
      else "nil"
      end
    end
    
    #
    # generate line to set a property
    # i.e. result.Property = nil # property_type + valuemap
    #
    def property_setter_line property, klass, result_name = "result"
      valuemap = property.ValueMap
      values = property.Values
      type = property.type
      if valuemap
	firstval = values ? values[0] : valuemap[0]
	if firstval.to_s =~ /\s/
	  firstval = "send(#{firstval.to_sym.inspect})"
	end
	default = "#{property.name}.#{firstval}"
        default = "[#{default}]" if type.array?
      else
        default = default_for_type type
      end
      bounds = bounds property, :MaxLen, :Max, :Min
      "#{result_name}.#{property.name} = #{default} # #{type} #{bounds} (-> #{klass.name})"
    end
    #
    # Class#each
    #
    def mkeach
      @out.puts "private"
      @out.comment
      @out.comment "Iterator for names and instances"
      @out.comment " yields references matching reference and properties"
      @out.comment
      @out.def "each", "context", "reference", "properties = nil", "want_instance = false"
      @out.puts "result = Cmpi::CMPIObjectPath.new reference.namespace, #{@klass.name.inspect}"
      @out.puts("if want_instance").inc
      @out.puts "result = Cmpi::CMPIInstance.new result"
      @out.puts "result.set_property_filter(properties) if properties"
      @out.end
      @out.puts
      @out.comment "Set key properties"
      @out.puts
      properties :keys do |prop, klass|
	@out.puts(property_setter_line prop, klass)
      end
      @out.puts("unless want_instance").inc
      @out.puts "yield result"
      @out.puts "return"
      @out.end
      @out.puts
      @out.comment "Instance: Set non-key properties"
      @out.puts
      properties :nokeys do |prop, klass|
	deprecated = prop.deprecated
	required = prop.required
	if required
	  @out.comment "Required !"
	  @out.puts "#{property_setter_line prop, klass}"
	else
	  @out.comment "Deprecated !" if deprecated
	  # using @out.comment would break the line at col 72
	  @out.puts "# #{property_setter_line prop, klass}"
	end
      end
      @out.puts "yield result"
      @out.end
      @out.puts "public"
    end
    #
    # Generate Class#initialize
    #
    def mknew
      @out.comment
      @out.comment "Provider initialization"
      @out.comment
      @out.def "initialize", "name", "broker", "context"
      @out.puts "@trace_file = STDERR"
      @out.puts "super broker"
      @out.end
    end

    #
    # Generate create_instance
    #
    def mkcreate
      @out.def "create_instance", "context", "result", "reference", "newinst"
      @out.puts "#{LOG} \"#{@name}.create_instance ref \#{reference}, newinst \#{newinst.inspect}\""
      @out.comment "Create instance according to reference and newinst"
      @out.puts "result.return_objectpath reference"
      @out.puts "result.done"
      @out.puts "true"
      @out.end
    end

    #
    # Generate enum_instance_names
    #
    def mkenum_instance_names
      @out.def "enum_instance_names", "context", "result", "reference"
      @out.puts "#{LOG} \"#{@name}.enum_instance_names ref \#{reference}\""
      @out.puts("each(context, reference) do |ref|").inc
      @out.puts "#{LOG} \"ref \#{ref}\""
      @out.puts "result.return_objectpath ref"
      @out.end
      @out.puts "result.done"
      @out.puts "true"
      @out.end
    end

    #
    # Generate enum_instances
    #
    def mkenum_instances
      @out.def "enum_instances", "context", "result", "reference", "properties"
      @out.puts "#{LOG} \"#{@name}.enum_instances ref \#{reference}, props \#{properties.inspect}\""
      @out.puts("each(context, reference, properties, true) do |instance|").inc
      @out.puts "#{LOG} \"instance \#{instance}\""
      @out.puts "result.return_instance instance"
      @out.end
      @out.puts "result.done"
      @out.puts "true"
      @out.end
    end

    #
    # Generate get_instance
    #
    def mkget_instance
      @out.def "get_instance", "context", "result", "reference", "properties"
      @out.puts "#{LOG} \"#{@name}.get_instance ref \#{reference}, props \#{properties.inspect}\""
      @out.puts("each(context, reference, properties, true) do |instance|").inc
      @out.puts "#{LOG} \"instance \#{instance}\""
      @out.puts "result.return_instance instance"
      @out.puts "break # only return first instance"
      @out.end
      @out.puts "result.done"
      @out.puts "true"
      @out.end
    end

    #
    # Generate set_instance
    #
    def mkset_instance
      @out.def "set_instance", "context", "result", "reference", "newinst", "properties"
      @out.puts "#{LOG} \"#{@name}.set_instance ref \#{reference}, newinst \#{newinst.inspect}, props \#{properties.inspect}\""
      @out.puts("properties.each do |prop|").inc
      @out.puts "newinst.send \"\#{prop.name}=\".to_sym, FIXME"
      @out.end
      @out.puts "result.return_instance newinst"
      @out.puts "result.done"
      @out.puts "true"
      @out.end
    end

    #
    # Generate delete_instance
    #
    def mkdelete_instance
      @out.def "delete_instance", "context", "result", "reference"
      @out.puts "#{LOG} \"#{@name}.delete_instance ref \#{reference}\""
      @out.puts "result.done"
      @out.puts "true"
      @out.end
    end

    #
    # Generate exec_query
    #
    def mkquery
      @out.comment "query : String"
      @out.comment "lang : String"
      @out.def "exec_query", "context", "result", "reference", "query", "lang"
      @out.puts "#{LOG} \"#{@name}.exec_query ref \#{reference}, query \#{query}, lang \#{lang}\""
      @out.printf "keys = ["
      first = true
      properties :keys do |property, klass|
        @out.write ", " unless first
        first = false
        @out.write "\"#{property.name}\""
      end
      @out.puts "]"
      @out.puts "expr = CMPISelectExp.new query, lang, keys"
      @out.puts("each(context, reference, expr.filter, true) do |instance|").inc
      @out.puts(  "if expr.match(instance)").inc
      @out.puts     "result.return_instance instance"
      @out.end
      @out.end
      @out.puts "result.done"
      @out.puts "true"
      @out.end
    end

    #
    # Generate cleanup
    #
    def mkcleanup
      @out.def "cleanup", "context", "terminating"
      @out.puts "#{LOG} \"#{@name}.cleanup terminating? \#{terminating}\""
      @out.puts "true"
      @out.end
    end

    def mktypemap
      @out.def("self.typemap")
      @out.puts("{").inc
      properties :all do |property, klass|
	t = property.type
	s = t.to_cmpi
	if t == CIM::ReferenceType
	  # use t.name to stay Ruby-compatible. t.to_s would print MOF syntax
	  @out.comment t.to_s
        elsif t == :string # check for Embedded{Instance,Object}
          if property.embeddedinstance?
            s = "Cmpi::embedded_instance"
          elsif property.embeddedobject?
            s = "Cmpi::embedded_object"
          end
        elsif t == :stringA # check for Embedded{Instance,Object}
          if property.embeddedinstance?
            s = "Cmpi::embedded_instanceA"
          elsif property.embeddedobject?
            s = "Cmpi::embedded_objectA"
          end
	end
	@out.puts "#{property.name.inspect} => #{s},"
      end
      @out.dec.puts "}"
      @out.end
    end
    
    def make_valuemap_header
      return if @valuemap_headers_done
      @out.comment
      @out.comment "----------------- valuemaps following, don't touch -----------------"
      @out.comment
      @valuemap_headers_done = true
    end
    #
    # make_valuemap
    # make one ValueMap class
    #
    def make_valuemap property
	t = property.type
	# get the Values and ValueMap qualifiers
	valuemap = property.ValueMap
	return unless valuemap
	make_valuemap_header
	values = property.Values
	@out.puts
	@out.puts("class #{property.name} < Cmpi::ValueMap").inc
	@out.def "self.map"
	@out.puts("{").inc
	# get to the array
	valuemap = valuemap
	# values might be nil, then only ValueMap given
	if values
	  values = values
	elsif !t.matches?(String)
	  raise "ValueMap missing Values for property #{property.name} with non-string type #{t}"
	end
	loop do
	  val = values.shift if values
	  map = valuemap.shift
	  if val.nil? && values
	    # have values but its empty
	    break unless map # ok, both nil
	    raise "#{property.name}: Values empty, ValueMap #{map}"
	  end
	  unless map
	    break unless val # ok, both nil
	    raise "#{property.name}: Values #{val}, ValueMap empty"
	  end
	  if val
	    if map =~ /\.\./
	      @out.comment "#{val.inspect} => #{map},"
	    else
	      @out.puts "#{val.inspect} => #{map},"
	    end
	  else
	    @out.puts "#{map.inspect} => #{map.to_sym.inspect},"
	  end
	end
	@out.dec.puts "}"
	@out.end
	@out.end
    end
    
    #
    # Generate valuemap classes
    #
    def mkvaluemaps
      properties :all do |property, klass|
	make_valuemap property
      end
      methods do |method, klass|
	make_valuemap method
      end
    end

    # base instance callbacks
    # use by association and instance providers
    def mkbaseinstance
      mkeach
      @out.puts
      mkenum_instance_names
      @out.puts
      mkenum_instances
      @out.puts
      mkget_instance
      @out.puts
    end

    def mkinstance
      mkbaseinstance
      mkcreate
      @out.puts
      mkset_instance
      @out.puts
      mkdelete_instance
      @out.puts
      mkquery
    end
    
    def mkargs args, name
      s = ""
      args.each do |arg|
	s << ", " unless s.empty?
	s << arg.name.inspect
	s << ", #{arg.type.to_cmpi}"
      end
      s
    end

    def explain_args args, text
      @out.comment "#{text} args"
      if args.empty?
        @out.comment "  - none -"
      end
      args.each do |arg|
	@out.comment "#{arg.name} : #{arg.type}", 1
	d = arg.description
	@out.comment("#{d}", 3) if d
	valuemap = arg.valuemap
	# values might be nil, then only ValueMap given
	if valuemap
	  @out.comment "Value can be one of", 3
	  valuemap = valuemap
	  values = arg.values
	  if values
	    values = values
	    loop do
	      s = values.shift
	      v = valuemap.shift
	      break unless v && s
	      @out.comment "#{s}: #{v}", 5
	    end
	  else
	    valuemap.each do |v|
	       @out.comment v, 5
	     end
	  end
	end
      end
      @out.comment
    end
    
    def mkmethods
      @out.comment "Methods"
      @out.puts
      methods do |method, klass|
	next if method.deprecated
	@out.comment "#{klass.name}: #{method.type} #{method.name}(...)"
	@out.comment
	input = []
	output = []
	method.parameters.each do |p|
          input << p if p.in?
	  output << p if p.out?
          STDERR.puts "#{p.name} is IN and OUT" if p.in? && p.out?
          STDERR.puts "#{p.name} is neither IN nor OUT" unless p.in? || p.out?
	end
	name = method.name
	decam = name.decamelize
        # type and argument information
	# must be array since order here is order of args passed to function
	# first element is list of input args (alternating name and type)
	# second is list of output args (starting with return type, then name and type of additional out args)
        # -> used by cmpi_bindings !
        @out.comment "type information for #{name}(...)"
        @out.comment "Array of 2 arrys. First array is input arguments as [<in_name1>, <in_type1>, ...]"
        @out.comment "  Second array is [<return type>, <out_name1>, <out_type1>, <out_name2>, <out_type2>, ...]"
	@out.puts "def #{decam}_args; [[#{mkargs(input, decam)}],[#{method.type.to_cmpi}, #{mkargs(output, decam)}]] end"
	@out.comment
	d = method.description.value rescue nil
	if d
	  @out.comment "#{d}"
	  @out.comment
	end
	v = method.values
	default_return_value = default_for_type method.type
	if v
	  @out.comment "See class #{method.name} for return values"
	  @out.comment
	  firstval = v[0]
	  if firstval.to_s =~ /\s/
	    firstval = "send(#{firstval.to_sym.inspect})"
	  end
	  default_return_value = "#{name}.#{firstval}"
	end
	explain_args input, "Input"
	explain_args output, "Additional output"
	args = ["#{decam}", "context", "reference"]
	input.each do |arg|
	  args << arg.name.decamelize
	end
	@out.def *args
	args.shift
	log = ""
	args.each do |arg|
	  log << ", " unless log.empty?
	  log << "\#{#{arg}}"
	end
	@out.puts "#{LOG} \"#{decam} #{log}\""
        
        # Empty arrays are not transferred by sfcc/cimxml, end up as nil
        input.each do |arg|
          next unless arg.type.array?
          @out.puts "#{arg.name.decamelize} ||= []"
        end
        
	args = [ "method_return_value" ]
        @out.puts "method_return_value = #{default_return_value} # #{method.type}"
        if output.size > 0
          @out.puts
          @out.comment "Output arguments"
          output.each do |arg|
            name = arg.name.decamelize
            @out.puts "#{name} = nil # #{arg.type}"
            args << name
          end
        end
        @out.puts
	@out.comment " function body goes here"
        @out.puts
	if args.size > 1
	  @out.puts "return [#{args.join(', ')}]"
	else
	  @out.puts "return #{args[0]}"
	end
	@out.end
	@out.puts
      end

#      @out.puts
#      @out.def "invoke_method", "context", "result", "reference", "method", "argsin", "argsout"
#      @out.comment "method names and parameter names are case-insensitive !"
#      @out.puts "#{LOG} \"invoke_method \#{context}, \#{result}, \#{reference}, \#{method}, \#{argsin}, \#{argsout}\""
#      @out.end
    end
    
    def mkassociations
      @out.comment "Associations"
      @out.def "associator_names", "context", "result", "reference", "assoc_class", "result_class", "role", "result_role"
      @out.puts "#{LOG} \"#{@name}.associator_names \#{context}, \#{result}, \#{reference}, \#{assoc_class}, \#{result_class}, \#{role}, \#{result_role}\""
      @out.end
      @out.puts
      @out.def "associators", "context", "result", "reference", "assoc_class", "result_class", "role", "result_role", "properties"
      @out.puts "#{LOG} \"#{@name}.associators \#{context}, \#{result}, \#{reference}, \#{assoc_class}, \#{result_class}, \#{role}, \#{result_role}, \#{properties}\""
      @out.end
      @out.puts
      @out.def "reference_names", "context", "result", "reference", "result_class", "role"
      @out.puts "#{LOG} \"#{@name}.reference_names \#{context}, \#{result}, \#{reference}, \#{result_class}, \#{role}\""
      @out.puts("each(context, reference) do |ref|").inc
      @out.puts "result.return_objectpath ref"
      @out.end
      @out.puts "result.done"
      @out.puts "true"
      @out.end
      @out.puts
      @out.def "references", "context", "result", "reference", "result_class", "role", "properties"
      @out.puts "#{LOG} \"#{@name}.references \#{context}, \#{result}, \#{reference}, \#{result_class}, \#{role}, \#{properties}\""
      @out.puts("each(context, reference, properties, true) do |instance|").inc
      @out.puts "result.return_instance instance"
      @out.end
      @out.puts "result.done"
      @out.puts "true"
      @out.end

    end
    
    def mkindications
      @out.comment "Indications"
    end

    def providertypes
      mask = Genprovider.classmask @klass
      res = []
      res << "MethodProvider" if (mask & METHOD_MASK) != 0
      res << "AssociationProvider" if (mask & ASSOCIATION_MASK) != 0
      res << "IndicationProvider" if (mask & INDICATION_MASK) != 0
      res << "InstanceProvider" if (mask & INSTANCE_MASK) != 0

      [res, mask]
    end

    #
    # generate provider code for class 'c'
    #
    # returns providername
    #

    def initialize c, name, out
      @klass = c
      @out = out

      if name[0,1] == name[0,1].downcase
        raise "Provider name (#{name}) must start with upper case"
      end
      @name = name

      #
      # Header: class name, provider name (Class qualifier 'provider')
      #

      @out.comment
      @out.comment "Provider #{name} for class #{@klass.name}:#{@klass.class}"
      @out.comment

      @out.puts("require 'syslog'").puts
      @out.puts("require 'cmpi/provider'").puts
      @out.puts("module Cmpi").inc

      Genprovider::Class.mkdescription @out, @klass
      if @klass.parent
	Genprovider::Class.mkdescription @out, @klass.parent
      end
      p,mask = providertypes

      @out.puts("class #{name} < #{p.shift}").inc

      @out.puts
      p.each do |t|
	@out.puts "include #{t}IF"
      end
      mknew
      @out.puts
      mkcleanup
      @out.puts
      mktypemap
      @out.puts
      if (mask & METHOD_MASK) != 0
	STDERR.puts "  Generating Method provider"
	mkmethods
	@out.puts
      end
      if (mask & ASSOCIATION_MASK) != 0
	STDERR.puts "  Generating Association provider"
	mkbaseinstance
	mkassociations
      end
      if (mask & INDICATION_MASK) != 0
	STDERR.puts "  Generating Indication provider"
	mkindications
	@out.puts
      end
      if (mask & INSTANCE_MASK) != 0
	STDERR.puts "  Generating Instance provider"
	mkinstance
	@out.puts
      end
      
      mkvaluemaps
      @out.end # class
      @out.end # module
    end
  end
end

