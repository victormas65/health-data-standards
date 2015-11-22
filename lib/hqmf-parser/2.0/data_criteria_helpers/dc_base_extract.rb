module HQMF2
  # Contains straightforward extractions needed by the DataCriteria
  class DataCriteriaBaseExtractions
    include HQMF2::Utilities
    CONJUNCTION_CODE_TO_DERIVATION_OP = {
      'OR' => 'UNION',
      'AND' => 'XPRODUCT'
    }

    def initialize(entry)
      @entry = entry
    end

    def extract_local_variable_name
      lvn = @entry.at_xpath('./cda:localVariableName')
      lvn['value'] if lvn
    end

    def extract_child_criteria
      @entry.xpath("./*/cda:outboundRelationship[@typeCode='COMP']/cda:criteriaReference/cda:id", HQMF2::Document::NAMESPACES).collect do |ref|
        Reference.new(ref).id
      end.compact
    end

    def extract_derivation_operator
      codes = @entry.xpath("./*/cda:outboundRelationship[@typeCode='COMP']/cda:conjunctionCode/@code", HQMF2::Document::NAMESPACES)
      codes.inject(nil) do |d_op, code|
        fail 'More than one derivation operator in data criteria' if d_op && d_op != CONJUNCTION_CODE_TO_DERIVATION_OP[code.value]
        CONJUNCTION_CODE_TO_DERIVATION_OP[code.value]
      end
    end

    def extract_temporal_references
      @entry.xpath('./*/cda:temporallyRelatedInformation', HQMF2::Document::NAMESPACES).collect do |temporal_reference|
        TemporalReference.new(temporal_reference)
      end
    end

    def extract_subset_operators
      all_subset_operators.select do |operator|
        operator.type != 'UNION' && operator.type != 'XPRODUCT'
      end
    end

    def all_subset_operators
      @entry.xpath('./*/cda:excerpt', HQMF2::Document::NAMESPACES).collect do |subset_operator|
        SubsetOperator.new(subset_operator)
      end
    end

    def extract_template_ids
      @entry.xpath('./*/cda:templateId/cda:item', HQMF2::Document::NAMESPACES).collect do |template_def|
        HQMF2::Utilities.attr_val(template_def, '@root')
      end
    end

    def extract_negation
      negation = (attr_val('./*/@actionNegationInd') == 'true')
      if negation
        res = @entry.at_xpath('./*/cda:outboundRelationship/*/cda:code[@code="410666004"]/../cda:value/@valueSet', HQMF2::Document::NAMESPACES)
        negation_code_list_id = res.value if res
      else
        negation_code_list_id = nil
      end
      [negation, negation_code_list_id]
    end
  end
end
