require 'nokogiri'  # FIXME: Implement using different modules as in RDF::TriX

module RDF::RDFa
  ##
  # An RDFa parser in Ruby
  #
  # Based on processing rules described here:
  # @see http://www.w3.org/TR/rdfa-syntax/#s_model RDFa 1.0
  # @see http://www.w3.org/TR/2011/WD-rdfa-core-20110331/ RDFa Core 1.1
  # @see http://www.w3.org/TR/2011/WD-xhtml-rdfa-20110331/ XHTML+RDFa 1.1
  #
  # @author [Gregg Kellogg](http://kellogg-assoc.com/)
  class Reader < RDF::Reader
    format Format
    XHTML = "http://www.w3.org/1999/xhtml"
    
    SafeCURIEorCURIEorURI = {
      :"rdfa1.0" => [:term, :safe_curie, :uri, :bnode],
      :"rdfa1.1" => [:safe_curie, :curie, :term, :uri, :bnode],
    }
    TERMorCURIEorAbsURI = {
      :"rdfa1.0" => [:term, :curie],
      :"rdfa1.1" => [:term, :curie, :absuri],
    }
    TERMorCURIEorAbsURIprop = {
      :"rdfa1.0" => [:curie],
      :"rdfa1.1" => [:term, :curie, :absuri],
    }

    NC_REGEXP = Regexp.new(
      %{^
        (?!\\\\u0301)             # &#x301; is a non-spacing acute accent.
                                  # It is legal within an XML Name, but not as the first character.
        (  [a-zA-Z_]
         | \\\\u[0-9a-fA-F]
        )
        (  [0-9a-zA-Z_\.-]
         | \\\\u([0-9a-fA-F]{4})
        )*
      $},
      Regexp::EXTENDED)
  
    # Host language
    # @attr [:xml1, :xhtml1, :xhtml5, :html4, :html5, :svg]
    attr_reader :host_language
    
    # Version
    # @attr [:"rdfa1.0", :"rdfa1.1"]
    attr_reader :version
    
    ##
    # Returns the base URI determined by this reader.
    #
    # @attr [RDF::URI]
    attr_reader :base_uri

    # The Recursive Baggage
    # @private
    class EvaluationContext # :nodoc:
      # The base.
      #
      # This will usually be the URL of the document being processed,
      # but it could be some other URL, set by some other mechanism,
      # such as the (X)HTML base element. The important thing is that it establishes
      # a URL against which relative paths can be resolved.
      #
      # @return [URI]
      attr :base, true
      # The parent subject.
      #
      # The initial value will be the same as the initial value of base,
      # but it will usually change during the course of processing.
      #
      # @return [URI]
      attr :parent_subject, true
      # The parent object.
      #
      # In some situations the object of a statement becomes the subject of any nested statements,
      # and this property is used to convey this value.
      # Note that this value may be a bnode, since in some situations a number of nested statements
      # are grouped together on one bnode.
      # This means that the bnode must be set in the containing statement and passed down,
      # and this property is used to convey this value.
      #
      # @return URI
      attr :parent_object, true
      # A list of current, in-scope URI mappings.
      #
      # @return [Hash{Symbol => String}]
      attr :uri_mappings, true
      # A list of current, in-scope Namespaces. This is the subset of uri_mappings
      # which are defined using xmlns.
      #
      # @return [Hash{String => Namespace}]
      attr :namespaces, true
      # A list of incomplete triples.
      #
      # A triple can be incomplete when no object resource
      # is provided alongside a predicate that requires a resource (i.e., @rel or @rev).
      # The triples can be completed when a resource becomes available,
      # which will be when the next subject is specified (part of the process called chaining).
      #
      # @return [Array<Array<URI, Resource>>]
      attr :incomplete_triples, true
      # The language. Note that there is no default language.
      #
      # @return [Symbol]
      attr :language, true
      # The term mappings, a list of terms and their associated URIs.
      #
      # This specification does not define an initial list.
      # Host Languages may define an initial list.
      # If a Host Language provides an initial list, it should do so via an RDFa Profile document.
      #
      # @return [Hash{Symbol => URI}]
      attr :term_mappings, true
      # The default vocabulary
      #
      # A value to use as the prefix URI when a term is used.
      # This specification does not define an initial setting for the default vocabulary.
      # Host Languages may define an initial setting.
      #
      # @return [URI]
      attr :default_vocabulary, true

      # @param [RDF::URI] base
      # @param [Hash] host_defaults
      # @option host_defaults [Hash{String => URI}] :term_mappings Hash of NCName => URI
      # @option host_defaults [Hash{String => URI}] :vocabulary Hash of prefix => URI
      def initialize(base, host_defaults)
        # Initialize the evaluation context, [5.1]
        @base = base
        @parent_subject = @base
        @parent_object = nil
        @namespaces = {}
        @incomplete_triples = []
        @language = nil
        @uri_mappings = host_defaults.fetch(:uri_mappings, {})
        @term_mappings = host_defaults.fetch(:term_mappings, {})
        @default_vocabulary = host_defaults.fetch(:vocabulary, nil)
      end

      # Copy this Evaluation Context
      #
      # @param [EvaluationContext] from
      def initialize_copy(from)
        # clone the evaluation context correctly
        @uri_mappings = from.uri_mappings.clone
        @incomplete_triples = from.incomplete_triples.clone
        @namespaces = from.namespaces.clone
      end
      
      def inspect
        v = ['base', 'parent_subject', 'parent_object', 'language', 'default_vocabulary'].map do |a|
          "#{a}='#{self.send(a).inspect}'"
        end
        v << "uri_mappings[#{uri_mappings.keys.length}]"
        v << "incomplete_triples[#{incomplete_triples.length}]"
        v << "term_mappings[#{term_mappings.keys.length}]"
        v.join(", ")
      end
    end

    ##
    # Initializes the RDFa reader instance.
    #
    # @param  [Nokogiri::HTML::Document, Nokogiri::XML::Document, IO, File, String] input
    #   the input stream to read
    # @param  [Hash{Symbol => Object}] options
    #   any additional options
    # @option options [Encoding] :encoding     (Encoding::UTF_8)
    #   the encoding of the input stream (Ruby 1.9+)
    # @option options [Boolean]  :validate     (false)
    #   whether to validate the parsed statements and values
    # @option options [Boolean]  :canonicalize (false)
    #   whether to canonicalize parsed literals
    # @option options [Boolean]  :intern       (true)
    #   whether to intern all parsed URIs
    # @option options [Hash]     :prefixes     (Hash.new)
    #   the prefix mappings to use (not supported by all readers)
    # @option options [#to_s]    :base_uri     (nil)
    #   the base URI to use when resolving relative URIs
    # @option options [:xml1, :xhtml1, :xhtml5, :html4, :html5, :svg] :host_language (:xhtml1)
    #   Host Language
    # @option options [:"rdfa1.0", :"rdfa1.1"] :version (:"rdfa1.1")
    #   Parser version information
    # @option options [Graph]    :processor_graph (nil)
    #   Graph to record information, warnings and errors.
    # @option options [Array] :debug
    #   Array to place debug messages
    # @return [reader]
    # @yield  [reader] `self`
    # @yieldparam  [RDF::Reader] reader
    # @yieldreturn [void] ignored
    # @raise [Error]:: Raises RDF::ReaderError if _validate_
    def initialize(input = $stdin, options = {}, &block)
      super do
        @debug = options[:debug]
        @base_uri = uri(options[:base_uri])

        detect_host_language_version(input, options)
        
        @processor_graph = options[:processor_graph]

        @doc = case input
        when Nokogiri::HTML::Document, Nokogiri::XML::Document
          input
        else
          # Try to detect charset from input
          options[:encoding] ||= input.charset if input.respond_to?(:charset)
          
          # Otherwise, default is utf-8
          options[:encoding] ||= 'utf-8'

          case @host_language
          when :html4, :html5
            Nokogiri::HTML.parse(input, @base_uri.to_s, options[:encoding])
          else
            Nokogiri::XML.parse(input, @base_uri.to_s, options[:encoding])
          end
        end
        
        if (@doc.nil? || @doc.root.nil?)
          add_error(nil, "Empty document", RDF::RDFA.DocumentError)
          raise RDF::ReaderError, "Empty Document"
        end
        add_warning(nil, "Synax errors:\n#{@doc.errors}", RDF::RDFA.DocumentError) if !@doc.errors.empty? && validate?

        # Section 4.2 RDFa Host Language Conformance
        #
        # The Host Language may require the automatic inclusion of one or more default RDFa Profiles.
        @host_defaults = {
          :vocabulary   => nil,
          :uri_mappings => {},
          :profiles     => [],
        }

        if @version == :"rdfa1.0"
          # Add default term mappings
          @host_defaults[:term_mappings] = %w(
            alternate appendix bookmark cite chapter contents copyright first glossary help icon index
            last license meta next p3pv1 prev role section stylesheet subsection start top up
            ).inject({}) { |hash, term| hash[term] = RDF::XHV[term]; hash }
        end

        case @host_language
        when :xml1, :svg
          @host_defaults[:profiles] = [XML_RDFA_PROFILE]
        when :xhtml1, :xhtml5, :html4, :html5
          @host_defaults[:profiles] = [XML_RDFA_PROFILE, XHTML_RDFA_PROFILE]
        end

        add_info(@doc, "version = #{@version},  host_language = #{@host_language}")

        block.call(self) if block_given?
      end
    end

    # Determine the host language and/or version from options and the input document
    def detect_host_language_version(input, options)
      @host_language = options[:host_language] ? options[:host_language].to_sym : nil
      @version = options[:version] ? options[:version].to_sym : nil
      return if @host_language && @version
      
      # Snif version based on input
      case input
      when Nokogiri::XML::Document, Nokogiri::HTML::Document
        doc_type_string = input.doctype.to_s
        version_attr = input.root && input.root.attribute("version").to_s
        root_element = input.root.name.downcase
        root_namespace = input.root.namespace.to_s
        root_attrs = input.root.attributes
        content_type = case
        when root_element == "html" && input.is_a?(Nokogiri::HTML::Document)
          "text/html"
        when root_element == "html" && input.is_a?(Nokogiri::XML::Document)
          "application/xhtml+html"
        end
      else
        content_type = input.content_type if input.respond_to?(:content_type)

        # Determine from head of document
        head = if input.respond_to?(:read)
          input.rewind
          string = input.read(1000)
          input.rewind
          string
        else
          input.to_s[0..1000]
        end
        
        doc_type_string = head.match(%r(<!DOCTYPE[^>]*>)m).to_s
        root = head.match(%r(<[^!\?>]*>)m).to_s
        root_element = root.match(%r(^<(\S+)[ >])) ? $1 : ""
        version_attr = root.match(/version\s+=\s+(\S+)[\s">]/m) ? $1 : ""
        head_element = head.match(%r(<head.*<\/head>)mi)
        head_doc = Nokogiri::HTML.parse(head_element.to_s)
        
        # May determine content-type and/or charset from meta
        # Easist way is to parse head into a document and iterate
        # of CSS matches
        head_doc.css("meta").each do |e|
          if e.attr("http-equiv").to_s.downcase == 'content-type'
            content_type, e = e.attr("content").to_s.downcase.split(";")
            options[:encoding] = $1.downcase if e.to_s =~ /charset=([^\s]*)$/i
          elsif e.attr("charset")
            options[:encoding] = e.attr("charset").to_s.downcase
          end
        end
      end

      # Already using XML parser, determine from DOCTYPE and/or root element
      @version ||= :"rdfa1.0" if doc_type_string =~ /RDFa 1\.0/
      @version ||= :"rdfa1.0" if version_attr =~ /RDFa 1\.0/
      @version ||= :"rdfa1.1" if version_attr =~ /RDFa 1\.1/
      @version ||= :"rdfa1.1"

      @host_language ||= case content_type
      when "application/xml"  then :xml1
      when "image/svg+xml"    then :svg
      when "text/html"
        case doc_type_string
        when /html 4/i        then :html4
        when /xhtml/i         then :xhtml1
        when /html/i          then :html5
        end
      when "application/xhtml+xml"
        case doc_type_string
        when /html 4/i        then :html4
        when /xhtml/i         then :xhtml1
        when /html/i          then :xhtml5
        end
      else
        case root_element
        when /svg/i           then :svg
        when /html/i          then :html4
        end
      end
      
      @host_language ||= :xml1
    end
    
    ##
    # Iterates the given block for each RDF statement in the input.
    #
    # @yield  [statement]
    # @yieldparam [RDF::Statement] statement
    # @return [void]
    def each_statement(&block)
      @callback = block

      # Add prefix definitions from host defaults
      @host_defaults[:uri_mappings].each_pair do |prefix, value|
        prefix(prefix, value)
      end

      # parse
      parse_whole_document(@doc, @base_uri)
    end

    ##
    # Iterates the given block for each RDF triple in the input.
    #
    # @yield  [subject, predicate, object]
    # @yieldparam [RDF::Resource] subject
    # @yieldparam [RDF::URI]      predicate
    # @yieldparam [RDF::Value]    object
    # @return [void]
    def each_triple(&block)
      each_statement do |statement|
        block.call(*statement.to_triple)
      end
    end
    
    private

    # Keep track of allocated BNodes
    def bnode(value = nil)
      @bnode_cache ||= {}
      @bnode_cache[value.to_s] ||= RDF::Node.new(value)
    end
    
    # Figure out the document path, if it is a Nokogiri::XML::Element or Attribute
    def node_path(node)
      "<#{@base_uri}>" + case node
      when Nokogiri::XML::Node then node.display_path
      else node.to_s
      end
    end
    
    # Add debug event to debug array, if specified
    #
    # @param [XML Node, any] node:: XML Node or string for showing context
    # @param [String] message::
    def add_debug(node, message)
      add_processor_message(node, message, RDF::RDFA.Info)
    end

    def add_info(node, message, process_class = RDF::RDFA.Info)
      add_processor_message(node, message, process_class)
    end
    
    def add_warning(node, message, process_class = RDF::RDFA.Warning)
      add_processor_message(node, message, process_class)
    end
    
    def add_error(node, message, process_class = RDF::RDFA.Error)
      add_processor_message(node, message, process_class)
      raise RDF::ReaderError, message if validate?
    end
    
    def add_processor_message(node, message, process_class)
      puts "#{node_path(node)}: #{message}" if ::RDF::RDFa.debug?
      @debug << "#{node_path(node)}: #{message}" if @debug.is_a?(Array)
      if @processor_graph
        n = RDF::Node.new
        @processor_graph << RDF::Statement.new(n, RDF["type"], process_class)
        @processor_graph << RDF::Statement.new(n, RDF::DC.description, message)
        @processor_graph << RDF::Statement.new(n, RDF::DC.date, RDF::Literal::Date.new(DateTime.now))
        @processor_graph << RDF::Statement.new(n, RDF::RDFA.context, @base_uri)
        nc = RDF::Node.new
        @processor_graph << RDF::Statement.new(nc, RDF["type"], RDF::PTR.XPathPointer)
        @processor_graph << RDF::Statement.new(nc, RDF::PTR.expression, node.path) if node.respond_to?(:path)
        @processor_graph << RDF::Statement.new(n, RDF::RDFA.context, nc)
      end
    end

    # add a statement, object can be literal or URI or bnode
    #
    # @param [Nokogiri::XML::Node, any] node:: XML Node or string for showing context
    # @param [URI, BNode] subject:: the subject of the statement
    # @param [URI] predicate:: the predicate of the statement
    # @param [URI, BNode, Literal] object:: the object of the statement
    # @return [Statement]:: Added statement
    # @raise [ReaderError]:: Checks parameter types and raises if they are incorrect if parsing mode is _validate_.
    def add_triple(node, subject, predicate, object)
      statement = RDF::Statement.new(subject, predicate, object)
      add_info(node, "statement: #{RDF::NTriples.serialize(statement)}")
      @callback.call(statement)
    end

    # Parsing an RDFa document (this is *not* the recursive method)
    def parse_whole_document(doc, base)
      # find if the document has a base element
      case @host_language
      when :xhtml1, :xhtml5, :html4, :html5
        base_el = doc.at_css("html>head>base")
        base = base_el.attribute("href").to_s.split("#").first if base_el
      else
        xml_base = doc.root.attribute_with_ns("base", RDF::XML.to_s)
        base = xml_base if xml_base
      end
      
      if (base)
        # Strip any fragment from base
        base = base.to_s.split("#").first
        base = uri(base)
        add_debug("", "parse_whole_doc: base='#{base}'")
      end

      # initialize the evaluation context with the appropriate base
      evaluation_context = EvaluationContext.new(base, @host_defaults)
      
      if @version != :"rdfa1.0"
        # Process default vocabularies
        process_profile(doc.root, @host_defaults[:profiles]) do |which, value|
          add_debug(doc.root, "parse_whole_document, #{which}: #{value.inspect}")
          case which
          when :uri_mappings        then evaluation_context.uri_mappings.merge!(value)
          when :term_mappings       then evaluation_context.term_mappings.merge!(value)
          when :default_vocabulary  then evaluation_context.default_vocabulary = value
          end
        end
      end
      
      traverse(doc.root, evaluation_context)
      add_debug("", "parse_whole_doc: traversal complete'")
    end
  
    # Parse and process URI mappings, Term mappings and a default vocabulary from @profile
    #
    # Yields each mapping
    def process_profile(element, profiles)
      profiles.
        map {|uri| uri(uri).normalize}.
        each do |uri|
        # Don't try to open ourselves!
        if @base_uri == uri
          add_debug(element, "process_profile: skip recursive profile <#{uri}>")
          next
        end

        old_debug = RDF::RDFa.debug?
        begin
          add_info(element, "process_profile: load <#{uri}>")
          RDF::RDFa.debug = false
          profile = Profile.find(uri)
        rescue Exception => e
          RDF::RDFa.debug = old_debug
          add_error(element, e.message, RDF::RDFA.ProfileReferenceError)
          raise # In case we're not in strict mode, we need to be sure processing stops
        ensure
          RDF::RDFa.debug = old_debug
        end

        # Add URI Mappings to prefixes
        profile.prefixes.each_pair do |prefix, value|
          prefix(prefix, value)
        end
        yield :uri_mappings, profile.prefixes unless profile.prefixes.empty?
        yield :term_mappings, profile.terms unless profile.terms.empty?
        yield :default_vocabulary, profile.vocabulary if profile.vocabulary
      end
    end

    # Extract the XMLNS mappings from an element
    def extract_mappings(element, uri_mappings, namespaces)
      # look for xmlns
      # (note, this may be dependent on @host_language)
      # Regardless of how the mapping is declared, the value to be mapped must be converted to lower case,
      # and the URI is not processed in any way; in particular if it is a relative path it is
      # not resolved against the current base.
      ns_defs = {}
      element.namespace_definitions.each do |ns|
        ns_defs[ns.prefix] = ns.href.to_s
      end

      # HTML parsing doesn't create namespace_definitions
      if ns_defs.empty?
        ns_defs = {}
        element.attributes.each do |k, v|
          ns_defs[$1] = v.to_s if k =~ /^xmlns(?:\:(.+))?/
        end
      end

      ns_defs.each do |prefix, href|
        # A Conforming RDFa Processor must ignore any definition of a mapping for the '_' prefix.
        next if prefix == "_"

        # Downcase prefix for RDFa 1.1
        pfx_lc = (@version == :"rdfa1.0" || prefix.nil?) ? prefix : prefix.downcase
        if prefix
          uri_mappings[pfx_lc.to_sym] = href
          namespaces[pfx_lc] ||= href
          prefix(pfx_lc, href)
          add_info(element, "extract_mappings: #{prefix} => <#{href}>")
        else
          add_info(element, "extract_mappings: nil => <#{href}>")
          namespaces[""] ||= href
        end
      end

      # Set mappings from @prefix
      # prefix is a whitespace separated list of prefix-name URI pairs of the form
      #   NCName ':' ' '+ xs:anyURI
      mappings = element.attribute("prefix").to_s.strip.split(/\s+/)
      while mappings.length > 0 do
        prefix, uri = mappings.shift.downcase, mappings.shift
        #puts "uri_mappings prefix #{prefix} <#{uri}>"
        next unless prefix.match(/:$/)
        prefix.chop!
        
        unless prefix.match(NC_REGEXP)
          add_error(element, "extract_mappings: Prefix #{prefix.inspect} does not match NCName production")
          next
        end

        # A Conforming RDFa Processor must ignore any definition of a mapping for the '_' prefix.
        next if prefix == "_"

        uri_mappings[prefix.to_s.empty? ? nil : prefix.to_s.to_sym] = uri
        prefix(prefix, uri)
        add_info(element, "extract_mappings: prefix #{prefix} => <#{uri}>")
      end unless @version == :"rdfa1.0"
    end

    # The recursive helper function
    def traverse(element, evaluation_context)
      if element.nil?
        add_error(element, "Can't parse nil element")
        return nil
      end
      
      add_debug(element, "traverse, ec: #{evaluation_context.inspect}")

      # local variables [7.5 Step 1]
      recurse = true
      skip = false
      new_subject = nil
      current_object_resource = nil
      uri_mappings = evaluation_context.uri_mappings.clone
      namespaces = evaluation_context.namespaces.clone
      incomplete_triples = []
      language = evaluation_context.language
      term_mappings = evaluation_context.term_mappings.clone
      default_vocabulary = evaluation_context.default_vocabulary

      current_object_literal = nil  # XXX Not explicit
    
      # shortcut
      attrs = element.attributes

      about = attrs['about']
      src = attrs['src']
      resource = attrs['resource']
      href = attrs['href']
      vocab = attrs['vocab']
      xml_base = element.attribute_with_ns("base", RDF::XML.to_s)
      base = xml_base.to_s if xml_base && ![:xhtml1, :xhtml5, :html4, :html5].include?(@host_language)
      base ||= evaluation_context.base

      # Pull out the attributes needed for the skip test.
      property = attrs['property'].to_s.strip if attrs['property']
      typeof = attrs['typeof'].to_s.strip if attrs.has_key?('typeof')
      datatype = attrs['datatype'].to_s if attrs['datatype']
      content = attrs['content'].to_s if attrs['content']
      rel = attrs['rel'].to_s.strip if attrs['rel']
      rev = attrs['rev'].to_s.strip if attrs['rev']

      attrs = {
        :about => about,
        :src => src,
        :resource => resource,
        :href => href,
        :vocab => vocab,
        :base => xml_base,
        :property => property,
        :typeof => typeof,
        :datatype => datatype,
        :rel => rel,
        :rev => rev,
      }.select{|k,v| v}
      
      add_debug(element, "traverse " + attrs.map{|a| "#{a.first}: #{a.last}"}.join(", ")) unless attrs.empty?

      # Default vocabulary [7.5 Step 2]
      # Next the current element is examined for any change to the default vocabulary via @vocab.
      # If @vocab is present and contains a value, its value updates the local default vocabulary.
      # If the value is empty, then the local default vocabulary must be reset to the Host Language defined default.
      unless vocab.nil?
        default_vocabulary = if vocab.to_s.empty?
          # Set default_vocabulary to host language default
          add_debug(element, "[Step 3] traverse, reset default_vocaulary to #{@host_defaults.fetch(:vocabulary, nil).inspect}")
          @host_defaults.fetch(:vocabulary, nil)
        else
          # Generate a triple indicating that the vocabulary is used
          add_triple(element, base_uri, RDF::RDFA.hasVocabulary, uri(vocab))

          uri(vocab)
        end
        add_debug(element, "[Step 2] traverse, default_vocaulary: #{default_vocabulary.inspect}")
      end
      
      # Local term mappings [7.5 Step 3]
      # Next, the current element is then examined for URI mapping s and these are added to the local list of URI mappings.
      # Note that a URI mapping will simply overwrite any current mapping in the list that has the same name
      extract_mappings(element, uri_mappings, namespaces)
    
      # Language information [7.5 Step 4]
      # From HTML5 [3.2.3.3]
      #   If both the lang attribute in no namespace and the lang attribute in the XML namespace are set
      #   on an element, user agents must use the lang attribute in the XML namespace, and the lang
      #   attribute in no namespace must be ignored for the purposes of determining the element's
      #   language.
      language = case
      when @doc.is_a?(Nokogiri::HTML::Document) && element.attributes["xml:lang"]
        element.attributes["xml:lang"].to_s
      when @doc.is_a?(Nokogiri::HTML::Document) && element.attributes["lang"]
        element.attributes["lang"].to_s
      when element.at_xpath("@xml:lang", "xml" => RDF::XML["uri"].to_s)
        element.at_xpath("@xml:lang", "xml" => RDF::XML["uri"].to_s).to_s
      when element.at_xpath("@lang")
        element.at_xpath("@lang").to_s
      else
        language
      end
      language = nil if language.to_s.empty?
      add_debug(element, "HTML5 [3.2.3.3] traverse, lang: #{language || 'nil'}") if language
    
      # rels and revs
      rels = process_uris(element, rel, evaluation_context, base,
                          :uri_mappings => uri_mappings,
                          :term_mappings => term_mappings,
                          :vocab => default_vocabulary,
                          :restrictions => TERMorCURIEorAbsURI[@version])
      revs = process_uris(element, rev, evaluation_context, base,
                          :uri_mappings => uri_mappings,
                          :term_mappings => term_mappings,
                          :vocab => default_vocabulary,
                          :restrictions => TERMorCURIEorAbsURI[@version])
    
      add_debug(element, "traverse, rels: #{rels.join(" ")}, revs: #{revs.join(" ")}") unless (rels + revs).empty?

      if !(rel || rev)
        # Establishing a new subject if no rel/rev [7.5 Step 5]
        # May not be valid, but can exist
        new_subject = if about
          process_uri(element, about, evaluation_context, base,
                      :uri_mappings => uri_mappings,
                      :restrictions => SafeCURIEorCURIEorURI[@version])
        elsif src
          process_uri(element, src, evaluation_context, base, :restrictions => [:uri])
        elsif resource
          process_uri(element, resource, evaluation_context, base,
                      :uri_mappings => uri_mappings,
                      :restrictions => SafeCURIEorCURIEorURI[@version])
        elsif href
          process_uri(element, href, evaluation_context, base, :restrictions => [:uri])
        end

        # If no URI is provided by a resource attribute, then the first match from the following rules
        # will apply:
        #   if @typeof is present, then new subject is set to be a newly created bnode.
        # otherwise,
        #   if parent object is present, new subject is set to the value of parent object.
        # Additionally, if @property is not present then the skip element flag is set to 'true';
        new_subject ||= if [:xhtml1, :xhtml5, :html4, :html5].include?(@host_language) && element.name =~ /^(head|body)$/
          # From XHTML+RDFa 1.1:
          # if no URI is provided, then first check to see if the element is the head or body element.
          # If it is, then act as if there is an empty @about present, and process it according to the rule for @about.
          uri(base)
        elsif element == @doc.root && base
          uri(base)
        elsif typeof
          RDF::Node.new
        else
          # if it's null, it's null and nothing changes
          skip = true unless property
          evaluation_context.parent_object
        end
        add_debug(element, "[Step 5] new_subject: #{new_subject}, skip = #{skip}")
      else
        # [7.5 Step 6]
        # If the current element does contain a @rel or @rev attribute, then the next step is to
        # establish both a value for new subject and a value for current object resource:
        new_subject = process_uri(element, about, evaluation_context, base,
                                  :uri_mappings => uri_mappings,
                                  :restrictions => SafeCURIEorCURIEorURI[@version]) ||
                      process_uri(element, src, evaluation_context, base,
                                  :uri_mappings => uri_mappings,
                                  :restrictions => [:uri])
      
        # If no URI is provided then the first match from the following rules will apply
        new_subject ||= if element == @doc.root && base
          uri(base)
        elsif [:xhtml1, :xhtml5, :html4, :html5].include?(@host_language) && element.name =~ /^(head|body)$/
          # From XHTML+RDFa 1.1:
          # if no URI is provided, then first check to see if the element is the head or body element.
          # If it is, then act as if there is an empty @about present, and process it according to the rule for @about.
          uri(base)
        elsif element.attributes['typeof']
          RDF::Node.new
        else
          # if it's null, it's null and nothing changes
          evaluation_context.parent_object
          # no skip flag set this time
        end
      
        # Then the current object resource is set to the URI obtained from the first match from the following rules:
        current_object_resource = if resource
          process_uri(element, resource, evaluation_context, base,
                      :uri_mappings => uri_mappings,
                      :restrictions => SafeCURIEorCURIEorURI[@version])
        elsif href
          process_uri(element, href, evaluation_context, base,
                      :restrictions => [:uri])
        end

        add_debug(element, "[Step 6] new_subject: #{new_subject}, current_object_resource = #{current_object_resource.nil? ? 'nil' : current_object_resource}")
      end
    
      # Process @typeof if there is a subject [Step 7]
      if new_subject and typeof
        # Typeof is TERMorCURIEorAbsURIs
        types = process_uris(element, typeof, evaluation_context, base,
                            :uri_mappings => uri_mappings,
                            :term_mappings => term_mappings,
                            :vocab => default_vocabulary,
                            :restrictions => TERMorCURIEorAbsURI[@version])
        add_debug(element, "typeof: #{typeof}")
        types.each do |one_type|
          add_triple(element, new_subject, RDF["type"], one_type)
        end
      end
    
      # Generate triples with given object [Step 8]
      if new_subject and current_object_resource
        rels.each do |r|
          add_triple(element, new_subject, r, current_object_resource)
        end
      
        revs.each do |r|
          add_triple(element, current_object_resource, r, new_subject)
        end
      elsif rel || rev
        # Incomplete triples and bnode creation [Step 9]
        add_debug(element, "[Step 9] incompletes: rels: #{rels}, revs: #{revs}")
        current_object_resource = RDF::Node.new
      
        rels.each do |r|
          incomplete_triples << {:predicate => r, :direction => :forward}
        end
      
        revs.each do |r|
          incomplete_triples << {:predicate => r, :direction => :reverse}
        end
      end
    
      # Establish current object literal [Step 10]
      if property
        properties = process_uris(element, property, evaluation_context, base,
                                  :uri_mappings => uri_mappings,
                                  :term_mappings => term_mappings,
                                  :vocab => default_vocabulary,
                                  :restrictions => TERMorCURIEorAbsURIprop[@version])

        properties.reject! do |p|
          if p.is_a?(RDF::URI)
            false
          else
            add_debug(element, "predicate #{p.inspect} must be a URI")
            true
          end
        end

        # get the literal datatype
        children_node_types = element.children.collect{|c| c.class}.uniq
      
        # the following 3 IF clauses should be mutually exclusive. Written as is to prevent extensive indentation.
        datatype = process_uri(element, datatype, evaluation_context, base,
                              :uri_mappings => uri_mappings,
                              :term_mappings => term_mappings,
                              :vocab => default_vocabulary,
                              :restrictions => TERMorCURIEorAbsURI[@version]) unless datatype.to_s.empty?
        begin
          current_object_literal = if !datatype.to_s.empty? && datatype.to_s != RDF.XMLLiteral.to_s
            # typed literal
            add_debug(element, "[Step 10] typed literal (#{datatype})")
            RDF::Literal.new(content || element.inner_text.to_s, :datatype => datatype, :language => language, :validate => validate?, :canonicalize => canonicalize?)
          elsif @version == :"rdfa1.1"
            if datatype.to_s == RDF.XMLLiteral.to_s
              # XML Literal
              add_debug(element, "[Step 10(1.1)] XML Literal: #{element.inner_html}")

              # In order to maintain maximum portability of this literal, any children of the current node that are
              # elements must have the current in scope XML namespace declarations (if any) declared on the
              # serialized element using their respective attributes. Since the child element node could also
              # declare new XML namespaces, the RDFa Processor must be careful to merge these together when
              # generating the serialized element definition. For avoidance of doubt, any re-declarations on the
              # child node must take precedence over declarations that were active on the current node.
              begin
                RDF::Literal.new(element.inner_html,
                                :datatype => RDF.XMLLiteral,
                                :language => language,
                                :namespaces => namespaces,
                                :validate => validate?,
                                :canonicalize => canonicalize?)
              rescue ArgumentError => e
                add_error(element, e.message)
              end
            else
              # plain literal
              add_debug(element, "[Step 10(1.1)] plain literal")
              RDF::Literal.new(content || element.inner_text.to_s, :language => language, :validate => validate?, :canonicalize => canonicalize?)
            end
          else
            if content || (children_node_types == [Nokogiri::XML::Text]) || (element.children.length == 0) || datatype == ""
              # plain literal
              add_debug(element, "[Step 10 (1.0)] plain literal")
              RDF::Literal.new(content || element.inner_text.to_s, :language => language, :validate => validate?, :canonicalize => canonicalize?)
            elsif children_node_types != [Nokogiri::XML::Text] and (datatype == nil or datatype.to_s == RDF.XMLLiteral.to_s)
              # XML Literal
              add_debug(element, "[Step 10 (1.0)] XML Literal: #{element.inner_html}")
              recurse = false
              RDF::Literal.new(element.inner_html,
                               :datatype => RDF.XMLLiteral,
                               :language => language,
                               :namespaces => namespaces,
                               :validate => validate?,
                               :canonicalize => canonicalize?)
            end
          end
        rescue ArgumentError => e
          add_error(element, e.message)
        end

        # add each property
        properties.each do |p|
          add_triple(element, new_subject, p, current_object_literal) if new_subject
        end
      end
    
      if not skip and new_subject && !evaluation_context.incomplete_triples.empty?
        # Complete the incomplete triples from the evaluation context [Step 11]
        add_debug(element, "[Step 11] complete incomplete triples: new_subject=#{new_subject}, completes=#{evaluation_context.incomplete_triples.inspect}")
        evaluation_context.incomplete_triples.each do |trip|
          if trip[:direction] == :forward
            add_triple(element, evaluation_context.parent_subject, trip[:predicate], new_subject)
          elsif trip[:direction] == :reverse
            add_triple(element, new_subject, trip[:predicate], evaluation_context.parent_subject)
          end
        end
      end

      # Create a new evaluation context and proceed recursively [Step 12]
      if recurse
        if skip
          if language == evaluation_context.language &&
              uri_mappings == evaluation_context.uri_mappings &&
              term_mappings == evaluation_context.term_mappings &&
              default_vocabulary == evaluation_context.default_vocabulary &&
              base == evaluation_context.base
            new_ec = evaluation_context
            add_debug(element, "[Step 12] skip: reused ec")
          else
            new_ec = evaluation_context.clone
            new_ec.base = base
            new_ec.language = language
            new_ec.uri_mappings = uri_mappings
            new_ec.namespaces = namespaces
            new_ec.term_mappings = term_mappings
            new_ec.default_vocabulary = default_vocabulary
            add_debug(element, "[Step 12] skip: cloned ec")
          end
        else
          # create a new evaluation context
          new_ec = EvaluationContext.new(base, @host_defaults)
          new_ec.parent_subject = new_subject || evaluation_context.parent_subject
          new_ec.parent_object = current_object_resource || new_subject || evaluation_context.parent_subject
          new_ec.uri_mappings = uri_mappings
          new_ec.namespaces = namespaces
          new_ec.incomplete_triples = incomplete_triples
          new_ec.language = language
          new_ec.term_mappings = term_mappings
          new_ec.default_vocabulary = default_vocabulary
          add_debug(element, "[Step 12] new ec")
        end
      
        element.children.each do |child|
          # recurse only if it's an element
          traverse(child, new_ec) if child.class == Nokogiri::XML::Element
        end
      end
    end

    # space-separated TERMorCURIEorAbsURI or SafeCURIEorCURIEorURI
    def process_uris(element, value, evaluation_context, base, options)
      return [] if value.to_s.empty?
      add_debug(element, "process_uris: #{value}")
      value.to_s.split(/\s+/).map {|v| process_uri(element, v, evaluation_context, base, options)}.compact
    end

    def process_uri(element, value, evaluation_context, base, options = {})
      return if value.nil?
      restrictions = options[:restrictions]
      add_debug(element, "process_uri: #{value}, restrictions = #{restrictions.inspect}")
      options = {:uri_mappings => {}}.merge(options)
      if !options[:term_mappings] && options[:uri_mappings] && value.to_s.match(/^\[(.*)\]$/) && restrictions.include?(:safe_curie)
        # SafeCURIEorCURIEorURI
        # When the value is surrounded by square brackets, then the content within the brackets is
        # evaluated as a CURIE according to the CURIE Syntax definition. If it is not a valid CURIE, the
        # value must be ignored.
        uri = curie_to_resource_or_bnode(element, $1, options[:uri_mappings], evaluation_context.parent_subject, restrictions)
        add_debug(element, "process_uri: #{value} => safeCURIE => <#{uri}>")
        uri
      elsif options[:term_mappings] && NC_REGEXP.match(value.to_s) && restrictions.include?(:term)
        # TERMorCURIEorAbsURI
        # If the value is an NCName, then it is evaluated as a term according to General Use of Terms in
        # Attributes. Note that this step may mean that the value is to be ignored.
        uri = process_term(element, value.to_s, options)
        add_debug(element, "process_uri: #{value} => term => <#{uri}>")
        uri
      else
        # SafeCURIEorCURIEorURI or TERMorCURIEorAbsURI
        # Otherwise, the value is evaluated as a CURIE.
        # If it is a valid CURIE, the resulting URI is used; otherwise, the value will be processed as a URI.
        uri = curie_to_resource_or_bnode(element, value, options[:uri_mappings], evaluation_context.parent_subject, restrictions)
        if uri
          add_debug(element, "process_uri: #{value} => CURIE => <#{uri}>")
        elsif @version == :"rdfa1.0" && value.to_s.match(/^xml/i)
          # Special case to not allow anything starting with XML to be treated as a URI
        elsif restrictions.include?(:absuri) || restrictions.include?(:uri)
          begin
            # AbsURI does not use xml:base
            if restrictions.include?(:absuri)
              uri = uri(value)
              unless uri.absolute?
                uri = nil
                raise RDF::ReaderError, "Relative URI #{value}" 
              end
            else
              uri = uri(base, Addressable::URI.parse(value))
            end
          rescue Addressable::URI::InvalidURIError => e
            add_warning(element, "Malformed prefix #{value}", RDF::RDFA.UnresolvedCURIE)
          rescue RDF::ReaderError => e
            add_debug(element, e.message)
            if value.to_s =~ /^\(^\w\):/
              add_warning(element, "Undefined prefix #{$1}", RDF::RDFA.UnresolvedCURIE)
            else
              add_warning(element, "Relative URI #{value}")
            end
          end
          add_debug(element, "process_uri: #{value} => URI => <#{uri}>")
        end
        uri
      end
    end
    
    # [7.4.3] General Use of Terms in Attributes
    #
    # @param [String] term:: term
    # @param [Hash] options:: Parser options, one of
    # <em>options[:term_mappings]</em>:: Term mappings
    # <em>options[:vocab]</em>:: Default vocabulary
    def process_term(element, value, options)
      if options[:term_mappings].is_a?(Hash)
        # If the term is in the local term mappings, use the associated URI (case sensitive).
        return uri(options[:term_mappings][value.to_s.to_sym]) if options[:term_mappings].has_key?(value.to_s.to_sym)
        
        # Otherwise, check for case-insensitive match
        options[:term_mappings].each_pair do |term, uri|
          return uri(uri) if term.to_s.downcase == value.to_s.downcase
        end
      end
      
      if options[:vocab]
        # Otherwise, if there is a local default vocabulary the URI is obtained by concatenating that value and the term.
        uri(options[:vocab] + value)
      else
        # Finally, if there is no local default vocabulary, the term has no associated URI and must be ignored.
        add_warning(element, "Term #{value} is not defined", RDF::RDFA.UnresolvedTerm)
        nil
      end
    end

    # From section 6. CURIE Syntax Definition
    def curie_to_resource_or_bnode(element, curie, uri_mappings, subject, restrictions)
      # URI mappings for CURIEs default to XHV, rather than the default doc namespace
      prefix, reference = curie.to_s.split(":")

      # consider the bnode situation
      if prefix == "_" && restrictions.include?(:bnode)
        # we force a non-nil name, otherwise it generates a new name
        # As a special case, _: is also a valid reference for one specific bnode.
        bnode(reference)
      elsif curie.to_s.match(/^:/)
        # Default prefix
        RDF::XHV[reference.to_s]
      elsif !curie.to_s.match(/:/)
        # No prefix, undefined (in this context, it is evaluated as a term elsewhere)
        nil
      else
        # Prefixes always downcased
        prefix = prefix.to_s.downcase unless @version == :"rdfa1.0"
        add_debug(element, "curie_to_resource_or_bnode check for #{prefix.to_s.to_sym.inspect} in #{uri_mappings.inspect}")
        ns = uri_mappings[prefix.to_s.to_sym]
        if ns
          uri(ns + reference.to_s)
        else
          add_debug(element, "curie_to_resource_or_bnode No namespace mapping for #{prefix}")
          nil
        end
      end
    end

    def uri(value, append = nil)
      value = RDF::URI.new(value)
      value = value.join(append) if append
      value.validate! if validate?
      value.canonicalize! if canonicalize?
      value = RDF::URI.intern(value) if intern?
      value
    end
  end
end