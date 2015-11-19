module HQMF2
  # Class representing an HQMF document
  class Document
    include HQMF2::Utilities, HQMF2::DocumentUtilities
    NAMESPACES = { 'cda' => 'urn:hl7-org:v3', 'xsi' => 'http://www.w3.org/2001/XMLSchema-instance', 'qdm' => 'urn:hhs-qdm:hqmf-r2-extensions:v1' }

    attr_reader :measure_period, :id, :hqmf_set_id, :hqmf_version_number, :populations, :attributes, :source_data_criteria

    # Create a new HQMF2::Document instance by parsing the given HQMF contents
    # @param [String] containing the HQMF contents to be parsed
    def initialize(hqmf_contents)
      setup_default_values(hqmf_contents)

      extract_criteria

      # Extract the population criteria and population collections
      pop_helper = HQMF2::PopulationHelper.new(@entry, @doc, self, @id_generator, @reference_ids)
      @populations, @population_criteria = pop_helper.extract_populations_and_criteria

      @reference_ids.uniq

      # Remove any data criteria from the main data criteria list that already has an equivalent member and no references to it
      # The goal of this is to remove any data criteria that should not be purely a source
      @data_criteria.reject! do |dc|
        covered_criteria?(dc)
      end
    end

    # Get the title of the measure
    # @return [String] the title
    def title
      @doc.at_xpath('cda:QualityMeasureDocument/cda:title/@value', NAMESPACES).inner_text
    end

    # Get the description of the measure
    # @return [String] the description
    def description
      description = @doc.at_xpath('cda:QualityMeasureDocument/cda:text/@value', NAMESPACES)
      description.nil? ? '' : description.inner_text
    end

    # Get all the population criteria defined by the measure
    # @return [Array] an array of HQMF2::PopulationCriteria
    def all_population_criteria
      @population_criteria
    end

    # Get a specific population criteria by id.
    # @param [String] id the population identifier
    # @return [HQMF2::PopulationCriteria] the matching criteria, raises an Exception if not found
    def population_criteria(id)
      find(@population_criteria, :id, id)
    end

    # Get all the data criteria defined by the measure
    # @return [Array] an array of HQMF2::DataCriteria describing the data elements used by the measure
    def all_data_criteria
      @data_criteria
    end

    # Get a specific data criteria by id.
    # @param [String] id the data criteria identifier
    # @return [HQMF2::DataCriteria] the matching data criteria, raises an Exception if not found
    def data_criteria(id)
      find(@data_criteria, :id, id)
    end

    # needed so data criteria can be added to a document from other objects
    def add_data_criteria(dc)
      @data_criteria << dc
    end

    def find_criteria_by_lvn(lvn)
      find(@data_criteria, :local_variable_name, lvn)
    end

    # Parse an XML document from the supplied contents
    # @return [Nokogiri::XML::Document]
    def self.parse(hqmf_contents)
      doc = hqmf_contents.is_a?(Nokogiri::XML::Document) ? hqmf_contents : Nokogiri::XML(hqmf_contents)
      doc.root.add_namespace_definition('cda', 'urn:hl7-org:v3')
      doc
    end

    def to_model
      dcs = all_data_criteria.collect(&:to_model)
      pcs = all_population_criteria.collect(&:to_model)
      sdc = source_data_criteria.collect(&:to_model)
      dcs = update_data_criteria(dcs, sdc)
      HQMF::Document.new(@id, @id, @hqmf_set_id, @hqmf_version_number, @cms_id,
                         title, description, pcs, dcs, sdc,
                         @attributes, @measure_period, @populations)
    end

    def find(collection, attribute, value)
      collection.find { |e| e.send(attribute) == value }
    end

    private

    def extract_criteria
      # Extract the data criteria
      extracted_criteria = []
      @doc.xpath('cda:QualityMeasureDocument/cda:component/cda:dataCriteriaSection/cda:entry', NAMESPACES).each do |entry|
        extracted_criteria << entry
      end

      # Extract the source data criteria from data criteria
      @source_data_criteria, collapsed_source_data_criteria = SourceDataCriteriaHelper.get_source_data_criteria_list(
        extracted_criteria, @data_criteria_references, @occurrences_map)

      extracted_criteria.each do |entry|
        criteria = DataCriteria.new(entry, @data_criteria_references, @occurrences_map)
        handle_data_criteria(criteria, collapsed_source_data_criteria)
        @data_criteria << criteria
      end
    end

    def handle_data_criteria(criteria, collapsed_source_data_criteria)
      # Sometimes there are multiple criteria with the same ID, even though they're different; in the HQMF
      # criteria refer to parent criteria via outboundRelationship, using an extension (aka ID) and a root;
      # we use just the extension to follow the reference, and build the lookup hash using that; since they
      # can repeat, we wind up overwriting some content. This becomes important when we want, for example,
      # the code_list_id and we overwrite the parent with the code_list_id with a child with the same ID
      # without the code_list_id. As a temporary approach, we only overwrite a data criteria reference if
      # it doesn't have a code_list_id. As a longer term approach we may want to use the root for lookups.
      if criteria && (@data_criteria_references[criteria.id].try(:code_list_id).nil?)
        @data_criteria_references[criteria.id] = criteria
      end
      if collapsed_source_data_criteria.key?(criteria.id)
        criteria.instance_variable_set(:@source_data_criteria, collapsed_source_data_criteria[criteria.id])
      end
      handle_variable(criteria) if criteria.variable

      @reference_ids.concat(criteria.children_criteria)
      if criteria.temporal_references
        criteria.temporal_references.each do |tr|
          @reference_ids << tr.reference.id if tr.reference.id != HQMF::Document::MEASURE_PERIOD_ID
        end
      end
    end

    def setup_default_values(hqmf_contents)
      @id_generator = IdGenerator.new
      @doc = @entry = Document.parse(hqmf_contents)

      @id = attr_val('cda:QualityMeasureDocument/cda:id/@extension') || attr_val('cda:QualityMeasureDocument/cda:id/@root').upcase
      @hqmf_set_id = attr_val('cda:QualityMeasureDocument/cda:setId/@extension') || attr_val('cda:QualityMeasureDocument/cda:setId/@root').upcase
      @hqmf_version_number = attr_val('cda:QualityMeasureDocument/cda:versionNumber/@value').to_i

      # overidden with correct year information later, but should be produce proper period
      # measure_period_def = @doc.at_xpath('cda:QualityMeasureDocument/cda:controlVariable/cda:measurePeriod/cda:value', NAMESPACES)
      # if measure_period_def
      #   @measure_period = EffectiveTime.new(measure_period_def).to_model
      # end

      # TODO: -- figure out if this is the correct thing to do -- probably not, but is
      # necessary to get the bonnie comparison to work.  Currently
      # defaulting measure period to a period of 1 year from 2012 to 2013 this is overriden during
      # calculation with correct year information .  Need to investigate parsing mp from meaures.
      @measure_period = extract_measure_period_or_default(true)

      # Extract measure attributes
      # TODO: Review
      @attributes = @doc.xpath('/cda:QualityMeasureDocument/cda:subjectOf/cda:measureAttribute', NAMESPACES).collect do |attribute|
        read_attribute(attribute)
      end

      @data_criteria = []
      @source_data_criteria = []
      @data_criteria_references = {}
      @occurrences_map = {}

      # Used to keep track of referenced data criteria ids
      @reference_ids = []
    end

    def extract_measure_period_or_default(default)
      if default
        mp_low = HQMF::Value.new('TS', nil, '201201010000', nil, nil, nil)
        mp_high = HQMF::Value.new('TS', nil, '201212312359', nil, nil, nil)
        mp_width = HQMF::Value.new('PQ', 'a', '1', nil, nil, nil)
        HQMF::EffectiveTime.new(mp_low, mp_high, mp_width)
      else
        measure_period_def = @doc.at_xpath('cda:QualityMeasureDocument/cda:controlVariable/cda:measurePeriod/cda:value', NAMESPACES)
        EffectiveTime.new(measure_period_def).to_model if measure_period_def
      end
    end

    def read_attribute(attribute)
      id = attribute.at_xpath('./cda:id/@root', NAMESPACES).try(:value)
      code = attribute.at_xpath('./cda:code/@code', NAMESPACES).try(:value)
      name = attribute.at_xpath('./cda:code/cda:displayName/@value', NAMESPACES).try(:value)
      value = attribute.at_xpath('./cda:value/@value', NAMESPACES).try(:value)

      id_obj = nil
      if attribute.at_xpath('./cda:id', NAMESPACES)
        id_obj = HQMF::Identifier.new(attribute.at_xpath('./cda:id/@xsi:type', NAMESPACES).try(:value), id,
                                      attribute.at_xpath('./cda:id/@extension', NAMESPACES).try(:value))
      end

      code_obj = nil
      if attribute.at_xpath('./cda:code', NAMESPACES)
        code_obj, null_flavor, o_text = handle_attribute_code(attribute, code, name)

        # Mapping for nil values to align with 1.0 parsing
        code = null_flavor if code.nil?
        name = o_text if name.nil?

      end

      value_obj = nil
      value_obj = handle_attribute_value(attribute, value) if attribute.at_xpath('./cda:value', NAMESPACES)

      # Handle the cms_id
      @cms_id = "CMS#{value}v#{@hqmf_version_number}" if name.include? 'eMeasure Identifier'

      HQMF::Attribute.new(id, code, value, nil, name, id_obj, code_obj, value_obj)
    end

    def handle_attribute_code(attribute, code, name)
      null_flavor = attribute.at_xpath('./cda:code/@nullFlavor', NAMESPACES).try(:value)
      o_text = attribute.at_xpath('./cda:code/cda:originalText/@value', NAMESPACES).try(:value)
      code_obj = HQMF::Coded.new(attribute.at_xpath('./cda:code/@xsi:type', NAMESPACES).try(:value) || 'CD',
                                 attribute.at_xpath('./cda:code/@codeSystem', NAMESPACES).try(:value),
                                 code,
                                 attribute.at_xpath('./cda:code/@valueSet', NAMESPACES).try(:value),
                                 name,
                                 null_flavor,
                                 o_text)
      [code_obj, null_flavor, o_text]
    end

    def handle_attribute_value(attribute, value)
      type = attribute.at_xpath('./cda:value/@xsi:type', NAMESPACES).try(:value)
      case type
      when 'II'
        if value.nil?
          value = attribute.at_xpath('./cda:value/@extension', NAMESPACES).try(:value)
        end
        HQMF::Identifier.new(type,
                             attribute.at_xpath('./cda:value/@root', NAMESPACES).try(:value),
                             attribute.at_xpath('./cda:value/@extension', NAMESPACES).try(:value))
      when 'ED'
        HQMF::ED.new(type, value, attribute.at_xpath('./cda:value/@mediaType', NAMESPACES).try(:value))
      when 'CD'
        HQMF::Coded.new('CD',
                        attribute.at_xpath('./cda:value/@codeSystem', NAMESPACES).try(:value),
                        attribute.at_xpath('./cda:value/@code', NAMESPACES).try(:value),
                        attribute.at_xpath('./cda:value/@valueSet', NAMESPACES).try(:value),
                        attribute.at_xpath('./cda:value/cda:displayName/@value', NAMESPACES).try(:value))
      else
        value.present? ? HQMF::GenericValueContainer.new(type, value) : HQMF::AnyValue.new(type)
      end
    end
  end

  # Handles generation of populations for the main document
  class PopulationHelper
    include HQMF2::Utilities

    def initialize(entry, doc, document, id_generator, reference_ids = {})
      @entry = entry
      @doc = doc
      remove_population_preconditions(@doc)
      @document = document
      @id_generator = id_generator
      @reference_ids = reference_ids
      @populations = []
      @population_criteria = []
      @stratifications = []
      @ids_by_hqmf_id = {}
      @population_counters = {}
    end

    # If a precondition references a population, remove it
    def remove_population_preconditions(doc)
      # population sections
      pop_ids = doc.xpath("//cda:populationCriteriaSection/cda:component[@typeCode='COMP']/*/cda:id", HQMF2::Document::NAMESPACES)
      # find the population entries and get their ids
      pop_ids.each do |p_id|
        doc.xpath("//cda:precondition[./cda:criteriaReference/cda:id[@extension='#{p_id['extension']}' and @root='#{p_id['root']}']]",
                  HQMF2::Document::NAMESPACES).remove
      end
    end

    # Returns the population descriptions and criteria found in this document
    def extract_populations_and_criteria
      has_observation = extract_observation
      document_populations = @doc.xpath('cda:QualityMeasureDocument/cda:component/cda:populationCriteriaSection', HQMF2::Document::NAMESPACES)
      # Sort the populations based on the id/extension, since the populations may be out of order; there doesn't seem to
      # be any other way that order is indicated in the HQMF
      document_populations = document_populations.sort_by { |pop| pop.at_xpath('cda:id/@extension', HQMF2::Document::NAMESPACES).try(:value) }
      number_of_populations = document_populations.length
      document_populations.each_with_index do |population_def, population_index|
        population = {}
        handle_base_populations(population_def, population)

        id_def = population_def.at_xpath('cda:id/@extension', HQMF2::Document::NAMESPACES)
        population['id'] = id_def ? id_def.value : "Population#{population_index}"
        title_def = population_def.at_xpath('cda:title/@value', HQMF2::Document::NAMESPACES)
        population['title'] = title_def ? title_def.value : "Population #{population_index}"

        population['OBSERV'] = 'OBSERV' if has_observation
        @populations << population

        handle_stratifications(population_def, number_of_populations, population, id_def, population_index)
      end

      # Push in the stratification populations after the unstratified populations
      @populations.concat(@stratifications)
      [@populations, @population_criteria]
    end

    # Extracts the measure observations, will return true if one is created
    def extract_observation
      has_observation = false
      # look for observation data in separate section but create a population for it if it exists
      observation_section = @doc.xpath('/cda:QualityMeasureDocument/cda:component/cda:measureObservationSection', HQMF2::Document::NAMESPACES)
      unless observation_section.empty?
        observation_section.xpath('cda:definition', HQMF2::Document::NAMESPACES).each do |criteria_def|
          criteria_id = 'OBSERV'
          criteria = PopulationCriteria.new(criteria_def, @document, @id_generator)
          criteria.type = 'OBSERV'
          # This section constructs a human readable id.  The first IPP will be IPP, the second will be IPP_1, etc.
          # This allows the populations to be more readable.  The alternative would be to have the hqmf ids in the populations,
          # which would work, but is difficult to read the populations.
          if @ids_by_hqmf_id["#{criteria.hqmf_id}"]
            criteria.create_human_readable_id(@ids_by_hqmf_id[criteria.hqmf_id])
          else
            criteria.create_human_readable_id(population_id_with_counter(criteria_id))
            @ids_by_hqmf_id["#{criteria.hqmf_id}"] = criteria.id
          end

          @population_criteria << criteria
          has_observation = true
        end
      end
      has_observation
    end

    # Builds populations based an a predfined set of expected populations
    def handle_base_populations(population_def, population)
      {
        HQMF::PopulationCriteria::IPP => 'initialPopulationCriteria',
        HQMF::PopulationCriteria::DENOM => 'denominatorCriteria',
        HQMF::PopulationCriteria::NUMER => 'numeratorCriteria',
        HQMF::PopulationCriteria::DENEXCEP => 'denominatorExceptionCriteria',
        HQMF::PopulationCriteria::DENEX => 'denominatorExclusionCriteria',
        HQMF::PopulationCriteria::MSRPOPL => 'measurePopulationCriteria',
        HQMF::PopulationCriteria::MSRPOPLEX => 'measurePopulationExclusionCriteria'
      }.each_pair do |criteria_id, criteria_element_name|
        criteria_def = population_def.at_xpath("cda:component[cda:#{criteria_element_name}]", HQMF2::Document::NAMESPACES)
        if criteria_def
          build_population_criteria(criteria_def, criteria_id, population)
        end
      end
    end

    # Generate the stratifications of populations, if any exist
    def handle_stratifications(population_def, number_of_populations, population, id_def, population_index)
      # handle stratifications (EP137, EP155)
      stratifier_criteria_xpath = "cda:component/cda:stratifierCriteria[not(cda:component/cda:measureAttribute/cda:code[@code  = 'SDE'])]/.."
      population_def.xpath(stratifier_criteria_xpath, HQMF2::Document::NAMESPACES).each_with_index do |criteria_def, criteria_def_index|
        # Skip this Stratification if any precondition doesn't contain any preconditions
        next unless PopulationCriteria.new(criteria_def, @document, @id_generator).preconditions.all? { |prcn| prcn.preconditions.length > 0 }

        index = number_of_populations + ((population_index - 1) * criteria_def.xpath('./*/cda:precondition').length) + criteria_def_index
        criteria_id = HQMF::PopulationCriteria::STRAT
        stratified_population = population.dup
        stratified_population['stratification'] = criteria_def.at_xpath('./*/cda:id/@root').try(:value) || "#{criteria_id}-#{criteria_def_index}"
        build_population_criteria(criteria_def, criteria_id, stratified_population)

        stratified_population['id'] = id_def ? "#{id_def.value} - Stratification #{criteria_def_index + 1}" : "Population#{index}"
        title_def = population_def.at_xpath('cda:title/@value', HQMF2::Document::NAMESPACES)
        stratified_population['title'] = title_def ? "#{title_def.value} - Stratification #{criteria_def_index + 1}" : "Population #{index}"
        @stratifications << stratified_population
      end
    end

    # Method to generate the criteria defining a population
    def build_population_criteria(criteria_def, criteria_id, population)
      criteria = PopulationCriteria.new(criteria_def, @document, @id_generator)

      # check to see if we have an identical population criteria.
      # this can happen since the hqmf 2.0 will export a DENOM, NUMER, etc for each population, even if identical.
      # if we have identical, just re-use it rather than creating DENOM_1, NUMER_1, etc.
      identical = @population_criteria.select { |pc| pc.to_model.hqmf_id == criteria.to_model.hqmf_id }

      @reference_ids.concat(criteria.to_model.referenced_data_criteria)

      if identical.empty?
        # this section constructs a human readable id.  The first IPP will be IPP, the second will be IPP_1, etc.
        # This allows the populations to be more readable.  The alternative would be to have the hqmf ids in the populations,
        # which would work, but is difficult to read the populations.
        if @ids_by_hqmf_id["#{criteria.hqmf_id}-#{population['stratification']}"]
          criteria.create_human_readable_id(@ids_by_hqmf_id["#{criteria.hqmf_id}-#{population['stratification']}"])
        else
          criteria.create_human_readable_id(population_id_with_counter(criteria_id))
          @ids_by_hqmf_id["#{criteria.hqmf_id}-#{population['stratification']}"] = criteria.id
        end

        @population_criteria << criteria
        population[criteria_id] = criteria.id
      else
        population[criteria_id] = identical.first.id
      end
    end

    # Returns a unique id for a given population (increments the id if already present)
    def population_id_with_counter(criteria_id)
      if @population_counters[criteria_id]
        @population_counters[criteria_id] += 1
        "#{criteria_id}_#{@population_counters[criteria_id]}"
      else
        @population_counters[criteria_id] = 0
        criteria_id
      end
    end
  end
end
