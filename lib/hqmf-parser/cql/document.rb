module HQMF2CQL
  
  # Class representing a HQMF v2 document that uses CQL for measure logic.
  class Document
    
    include HQMF2CQL::Utilities
    
    NAMESPACES = HQMF2CQL::Utilities::NAMESPACES

    attr_reader :measure_period, :id, :hqmf_set_id, :hqmf_version_number,
                :populations, :attributes, :source_data_criteria

    # Create a new HQMF2CQL::Document instance by parsing the given HQMF contents
    def initialize(hqmf_contents, use_default_measure_period = true)
      # Set up basic measure values
      setup_basic_values(hqmf_contents)
      
      # Extract attributes
      extract_measure_attributes(hqmf_contents, use_default_measure_period)

      # Extract data criteria
      extract_data_criteria

      # Extract the population criteria and population collections
      #pop_helper = HQMF2::DocumentPopulationHelper.new(@entry, @doc, self, @id_generator, @reference_ids)
      #@populations, @population_criteria = pop_helper.extract_populations_and_criteria
    end

    # Get the title of the measure
    def title
      @doc.at_xpath('cda:QualityMeasureDocument/cda:title/@value', NAMESPACES).inner_text
    end

    # Get the description of the measure
    def description
      description = @doc.at_xpath('cda:QualityMeasureDocument/cda:text/@value', NAMESPACES)
      description.nil? ? '' : description.inner_text
    end

    # Get all the population criteria defined by the measure
    def all_population_criteria
      @population_criteria || []
    end

    # Get a specific population criteria by id.
    def population_criteria(id)
      find(@population_criteria, :id, id)
    end

    # Get all the data criteria defined by the measure
    def all_data_criteria
      @data_criteria
    end

    # Get a specific data criteria by id.
    def data_criteria(id)
      find(@data_criteria, :id, id)
    end

    # Adds data criteria to the Document's criteria list
    # needed so data criteria can be added to a document from other objects
    def add_data_criteria(dc)
      @data_criteria << dc
    end

    # Parse an XML document from the supplied contents
    def self.parse(hqmf_contents)
      doc = hqmf_contents.is_a?(Nokogiri::XML::Document) ? hqmf_contents : Nokogiri::XML(hqmf_contents)
      doc.root.add_namespace_definition('cda', 'urn:hl7-org:v3')
      doc
    end

    # Finds a data criteria by it's local variable name
    def find_criteria_by_lvn(local_variable_name)
      find(@data_criteria, :local_variable_name, local_variable_name)
    end

    # Generates this classes hqmf-model equivalent
    def to_model
      dcs = all_data_criteria.collect(&:to_model)
      pcs = all_population_criteria.collect(&:to_model)
      sdc = source_data_criteria.collect(&:to_model)
      HQMF::Document.new(@id, @id, @hqmf_set_id, @hqmf_version_number, @cms_id,
                         title, description, pcs, dcs, sdc,
                         @attributes, @measure_period, @populations)
    end

    # Finds an element within the given collection that has an instance
    # variable or method of "attribute" with a value of "value"
    def find(collection, attribute, value)
      collection.find { |e| e.send(attribute) == value }
    end

    private

    # Sets up basic values for this class based on the given HQMF document.
    def setup_basic_values(hqmf_contents)
      @id_generator = IdGenerator.new
      @doc = @entry = Document.parse(hqmf_contents)
      @data_criteria = []
      @source_data_criteria = []
    end

    # Extracts measure attributes from the given HQMF document.
    def extract_measure_attributes(hqmf_contents, use_default_measure_period)
      # Extract id, set id, version number, and measure period
      @id = attr_val('cda:QualityMeasureDocument/cda:id/@extension') ||
            attr_val('cda:QualityMeasureDocument/cda:id/@root').upcase
      @hqmf_set_id = attr_val('cda:QualityMeasureDocument/cda:setId/@extension') ||
                     attr_val('cda:QualityMeasureDocument/cda:setId/@root').upcase
      @hqmf_version_number = attr_val('cda:QualityMeasureDocument/cda:versionNumber/@value')
      @measure_period = handle_measure_period(use_default_measure_period)

      # Extract measure attributes
      @attributes = @doc.xpath('/cda:QualityMeasureDocument/cda:subjectOf/cda:measureAttribute', NAMESPACES)
                    .collect do |attribute|
        handle_attribute(attribute)
      end
    end

    # Handles the measure period. Optionally, if the given parameter is set
    # to true, this method will return the default measure period (2012), as
    # used in Bonnie. Otherwise, this method will extract the measure period
    # from the HQMF.
    def handle_measure_period(default)
      if default
        mp_low = HQMF::Value.new('TS', nil, '201201010000', nil, nil, nil)
        mp_high = HQMF::Value.new('TS', nil, '201212312359', nil, nil, nil)
        mp_width = HQMF::Value.new('PQ', 'a', '1', nil, nil, nil)
        HQMF::EffectiveTime.new(mp_low, mp_high, mp_width)
      else
        measure_period_def = @doc.at_xpath('cda:QualityMeasureDocument/cda:controlVariable/cda:measurePeriod/cda:value',
                                           NAMESPACES)
        EffectiveTime.new(measure_period_def).to_model if measure_period_def
      end
    end

    # Parses the given HQMF attribute entry.
    def handle_attribute(attribute)
      id = attribute.at_xpath('./cda:id/@root', NAMESPACES).try(:value)
      code = attribute.at_xpath('./cda:code/@code', NAMESPACES).try(:value)
      name = attribute.at_xpath('./cda:code/cda:displayName/@value', NAMESPACES).try(:value)
      value = attribute.at_xpath('./cda:value/@value', NAMESPACES).try(:value)

      # Extract id tag
      id_obj = nil
      if attribute.at_xpath('./cda:id', NAMESPACES)
        id_obj = HQMF::Identifier.new(attribute.at_xpath('./cda:id/@xsi:type', NAMESPACES).try(:value),
                                      id,
                                      attribute.at_xpath('./cda:id/@extension', NAMESPACES).try(:value))
      end

      # Extract code tag
      code_obj = nil
      if attribute.at_xpath('./cda:code', NAMESPACES)
        code_obj, null_flavor, o_text = AttributeHelper.handle_attribute_code(attribute, code, name)

        # Mapping for nil values to align with 1.0 parsing
        code = null_flavor if code.nil?
        name = o_text if name.nil?
      end

      # Extract value tag
      value_obj = nil
      if attribute.at_xpath('./cda:value', NAMESPACES)
        value_obj = AttributeHelper.handle_attribute_value(attribute, value)
      end

      # Handle CMS id
      @cms_id = "CMS#{value}v#{@hqmf_version_number.to_i}" if name.include? 'eMeasure Identifier'

      HQMF::Attribute.new(id, code, value, nil, name, id_obj, code_obj, value_obj)
    end

    # Extracts data criteria from the HQMF document.
    def extract_data_criteria
      # Grab each data criteria entry from the HQMF
      extracted_data_criteria = []
      @doc.xpath('cda:QualityMeasureDocument/cda:component/cda:dataCriteriaSection/cda:entry', NAMESPACES).each do |entry|
        extracted_data_criteria << entry
        dc = HQMF2::DataCriteria.new(entry) # Create new data criteria
        sdc = dc.clone # Clone data criteria and make it a source
        sdc.id += '_source'

        # REVIEW: For HQMF + CQL, do we need both DC and SDC?
        @data_criteria << dc
        @source_data_criteria << sdc
      end
    end

  end
end
