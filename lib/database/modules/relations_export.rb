require 'i18n'

module Contentful
  module Exporter
    module Database
      module RelationsExport

        RELATIONS = [:many, :many_through, :aggregate_many, :aggregate_through, :has_one, :aggregate_has_one]

        def generate_relations_helper_indexes(relations)
          create_directory(config.helpers_dir)
          relations.each do |relation_type, linked_models|
            save_relation_foreign_keys(relation_type, linked_models) if RELATIONS.include?(relation_type.to_sym)
          end
        end

        def save_relation_foreign_keys(relation_type, linked_models)
          linked_models.each do |linked_model|
            save_relation_foreign_keys_for_model(linked_model, relation_type)
          end
        end

        def save_relation_foreign_keys_for_model(linked_model, relation_type)
          primary_id = linked_model[:primary_id]
          fail ArgumentError, "Missing #{primary_id} in relationship in Mapping JSON file" unless primary_id
          case relation_type.to_sym
            when :many_through, :aggregate_through
              related_model = linked_model[:through]
              related_model_id = linked_model[:foreign_id]
            when :many, :aggregate_many, :has_one, :aggregate_has_one
              related_model = linked_model[:relation_to]
              related_model_id = linked_model[:foreign_id] || :id
          end
          save_foreign_keys(related_model, primary_id, related_model_id)
        end

        def save_foreign_keys(related_model, primary_id, related_model_id)
          results = config.db[related_model.underscore.to_sym].each_with_object({}) do |row, res|
            add_index_to_helper_hash(res, row, primary_id, related_model_id)
          end
          write_json_to_file(config.helpers_dir + "/#{primary_id}_#{related_model.underscore}.json", results)
        end

        def add_index_to_helper_hash(results, row, primary_id, id)
          id, primary_id = id.to_sym, primary_id.to_sym
          if results[row[primary_id]].nil?
            results[row[primary_id]] = [row[id]] if row[id]
          else
            results[row[primary_id]] << row[id] if row[id]
          end
          results
        end

        def map_relations_to_links(model_name, relations)
          records = 0
          model_subdirectory = I18n.transliterate(model_content_type(model_name)).underscore.tr(' ', '_')
          Dir.glob("#{config.entries_dir}/#{model_subdirectory}/*json") do |entry_path|
            map_entry_relations(entry_path, model_name, relations, records)
            records += 1
          end
        end

        def relations_from_mapping
          mapping.each_with_object({}) do |(model_name, model_mapping), relations|
            relations[model_name] = model_mapping[:links] if model_mapping[:links].present?
          end
        end

        def map_entry_relations(entry_path, model_name, relations, record)
          relations.each do |relation_type, linked_models|
            logger.info "Mapping #{model_name} - relation: #{relation_type} - #{linked_models}, record: #{record}" if record % 1000 == 0
            map_entry_relation(entry_path, relation_type, linked_models, model_name)
          end
        end

        def map_entry_relation(entry_path, relation_type, linked_models, model_name)
          entry = JSON.parse(File.read(entry_path))
          linked_models.each do |linked_model|
            relationships(entry, entry_path, relation_type, model_name, linked_model)
          end
        end

        def relationships(entry, entry_path, relation_type, model_name, linked_model)
          case relation_type.to_sym
            when :belongs_to
              map_belongs_to_association(model_name, linked_model, entry, entry_path)
            when :has_one
              map_has_one_association(model_name, linked_model, entry, entry_path, :relation_to)
            when :many
              map_many_association(model_name, linked_model, entry, entry_path, :relation_to)
            when :many_through
              map_many_association(model_name, linked_model, entry, entry_path, :through)
            when :aggregate_through
              aggregate_data(model_name, linked_model, entry, entry_path, :through)
            when :aggregate_many
              aggregate_data(model_name, linked_model, entry, entry_path, :relation_to)
            when :aggregate_belongs
              aggregate_belongs(linked_model, entry, entry_path, :relation_to)
            when :aggregate_has_one
              aggregate_has_one(linked_model, entry, entry_path, :relation_to)
          end
        end

        def model_content_type(model_name)
          mapping[model_name][:content_type]
        end

        def map_belongs_to_association(model_name, linked_model, entry, entry_path)
          ct_link_type = contentful_field_attribute(model_name, linked_model, :type)
          ct_field_id = contentful_field_attribute(model_name, linked_model, :id)
          save_belongs_to_entries(linked_model, ct_link_type, ct_field_id, entry, entry_path)
        end

        def contentful_field_attribute(model_name, associated_model_attributes, type)
          contentful_model_hash(model_name)
          contentful_model_fields(model_name)
          contentful_associated_model_name(model_name, associated_model_attributes[:relation_to])

          associated_model = get_associated_model(associated_model_attributes)
          associated_content_type = model_content_type(model_name)
          contentful_associated_parameters(model_name, associated_model_attributes[:relation_to], associated_model)
          config.contentful_structure[associated_content_type][:fields][associated_model][type]
        end

        def contentful_model_hash(model_name)
          fail ArgumentError, "Missing #{model_name} in contentful structure JSON file" unless model_in_structure?(model_name)
        end

        def contentful_model_fields(model_name)
          fail ArgumentError, "Missing fields in #{model_name} in contentful structure JSON file" unless fields_in_structure?(model_name)
        end

        def contentful_associated_model_name(model_name, associated_model_name)
          fail ArgumentError, "Missing associated model content type name for #{model_name} in MAPPING JSON file" unless content_type_in_mapping?(associated_model_name)
        end

        def contentful_associated_parameters(model_name, associated_model_name, associated_model)
          fail ArgumentError, "Missing link field for #{associated_model_name} in #{model_name} in contentful structure JSON file!" unless associated_model_in_structure?(model_name, associated_model)
        end

        def model_in_structure?(model_name)
          config.contentful_structure[model_content_type(model_name)]
        end

        def fields_in_structure?(model_name)
          config.contentful_structure[model_content_type(model_name)][:fields]
        end

        def content_type_in_mapping?(model_name)
          model_content_type(model_name)
        end

        def associated_model_in_structure?(model_name, associated_model)
          config.contentful_structure[model_content_type(model_name)][:fields][associated_model]
        end

        def save_belongs_to_entries(linked_model, ct_link_type, ct_field_id, entry, entry_path)
          content_type = I18n.transliterate(model_content_type(linked_model[:relation_to])).underscore.tr(' ', '_')
          foreign_id = linked_model[:foreign_id]
          if entry[foreign_id].present?
            case ct_link_type
              when 'Asset'
                type = 'File'
              when 'Entry'
                type = 'Entry'
            end
            object = {
                'type' => type,
                'id' => "#{content_type}_#{entry[foreign_id]}"
            }
            write_json_to_file(entry_path, entry.merge!(ct_field_id => object))
          end
        end

        def get_associated_model(associated_model_attributes)
          associated_model_attributes.has_key?(:maps_to) ? associated_model_attributes[:maps_to] : model_content_type(associated_model_attributes[:relation_to])
        end

        def save_many_entries(linked_model, ct_field_id, entry, entry_path, related_to, ct_type)
          related_model = linked_model[related_to].underscore
          contentful_name = I18n.transliterate(model_content_type(linked_model[:relation_to])).underscore.tr(' ', '_')
          objects = entry[ct_field_id] || []
          associated_objects = add_associated_object_to_file(entry, related_model, contentful_name, linked_model[:primary_id], ct_type)
          objects.concat(associated_objects) if objects.present? && associated_objects.present? && objects.is_a?(Array)
          save_objects = objects.present? ? objects : associated_objects
          write_json_to_file(entry_path, entry.merge!(ct_field_id => save_objects)) if save_objects.present?
        end

        def save_has_one_entry(linked_model, ct_field_id, entry, entry_path, related_to, ct_type)
          related_model = linked_model[related_to].underscore
          contentful_name = I18n.transliterate(model_content_type(linked_model[:relation_to])).underscore.tr(' ', '_')
          associated_object = add_associated_object_to_file(entry, related_model, contentful_name, linked_model[:primary_id], ct_type)
          write_json_to_file(entry_path, entry.merge!(ct_field_id => associated_object.first)) if associated_object.present?
        end

        def map_many_association(model_name, linked_model, entry, entry_path, related_to)
          ct_field_id = contentful_field_attribute(model_name, linked_model, :id)
          ct_type = mapping[linked_model[:relation_to]][:type] if mapping[linked_model[:relation_to]]
          save_many_entries(linked_model, ct_field_id, entry, entry_path, related_to, ct_type)
        end

        def map_has_one_association(model_name, linked_model, entry, entry_path, related_to)
          ct_field_id = contentful_field_attribute(model_name, linked_model, :id)
          ct_type = mapping[linked_model[:relation_to]][:type] if mapping[linked_model[:relation_to]]
          save_has_one_entry(linked_model, ct_field_id, entry, entry_path, related_to, ct_type)
        end

        def add_associated_object_to_file(entry, related_model, contentful_name, primary_id, ct_type)
          Dir.glob("#{config.helpers_dir}/#{primary_id}_#{related_model}.json") do |through_file|
            hash_with_foreign_keys = JSON.parse(File.read(through_file))
            return build_hash_with_associated_objects(hash_with_foreign_keys, entry, contentful_name, ct_type)
          end
        end

        def build_hash_with_associated_objects(hash_with_foreign_keys, entry, contentful_name, ct_type)
          if hash_with_foreign_keys.has_key?(entry['database_id'].to_s)
            associated_objects = hash_with_foreign_keys[entry['database_id'].to_s].each_with_object([]) do |foreign_key, result|
              type = case ct_type
                       when 'entry'
                         contentful_name
                       when 'asset'
                         'File'
                     end
              result << {
                  'type' => type,
                  'id' => "#{contentful_name}_#{foreign_key}"
              }
            end
          end
          associated_objects
        end

        def aggregate_data(model_name, linked_model, entry, entry_path, related_to)
          ct_field_id = contentful_field_attribute(model_name, linked_model, :id)
          save_aggregated_entries(linked_model, ct_field_id, entry, entry_path, related_to)
        end

        def aggregate_has_one(linked_model, entry, entry_path, related_to)
          ct_field_id = linked_model[:save_as] || linked_model[:field]
          related_model = linked_model[related_to].underscore
          related_model_directory = I18n.transliterate(mapping[linked_model[related_to]][:content_type]).underscore.tr(' ', '_')
          save_aggregated_has_one_data(entry_path, entry, related_model, related_model_directory, linked_model, ct_field_id)
        end

        def save_aggregated_has_one_data(entry_path, entry, related_model, related_model_directory, linked_model, ct_field_id)
          primary_id = linked_model[:primary_id]
          hash_with_foreign_keys = JSON.parse(File.read("#{config.helpers_dir}/#{primary_id}_#{related_model}.json"))
          if hash_with_foreign_keys.has_key?(entry['database_id'].to_s)
            related_file_id = hash_with_foreign_keys[entry['database_id'].to_s].first if hash_with_foreign_keys[entry['database_id'].to_s].present?
            entry[ct_field_id] = JSON.parse(File.read("#{config.entries_dir}/#{related_model_directory}/#{related_model_directory}_#{related_file_id}.json"))[linked_model[:field]]
            write_json_to_file(entry_path, entry)
          end
        end

        def aggregate_belongs(linked_model, entry, entry_path, related_to)
          if entry[linked_model[:primary_id]]
            related_model = linked_model[related_to]
            ct_field_id = linked_model[:save_as] || linked_model[:field]
            related_model_directory = I18n.transliterate(mapping[related_model][:content_type]).underscore.tr(' ', '_')
            associated_foreign_key = related_model_directory + '_' + entry[linked_model[:primary_id]].to_s
            associated_object = JSON.parse(File.read("#{config.entries_dir}/#{related_model_directory}/#{associated_foreign_key}.json"))[linked_model[:field]]
            write_json_to_file(entry_path, entry.merge!(ct_field_id => associated_object))
          end
        end

        def save_aggregated_entries(linked_model, ct_field_id, entry, entry_path, related_to)
          ct_field = linked_model['save_as'] || ct_field_id
          related_model = linked_model[related_to].underscore
          contentful_name = model_content_type(linked_model[:relation_to]).underscore
          associated_objects = save_aggregated_object_to_file(entry, related_model, contentful_name, linked_model)
          write_json_to_file(entry_path, entry.merge!(ct_field => associated_objects)) if associated_objects.present?
        end

        def save_aggregated_object_to_file(entry, related_model, contentful_name, linked_model)
          primary_id = linked_model[:primary_id]
          Dir.glob("#{config.helpers_dir}/#{primary_id}_#{related_model}.json") do |through_file|
            hash_with_foreign_keys = JSON.parse(File.read(through_file))
            return hash_with_aggregate_objects(hash_with_foreign_keys, entry, contentful_name, linked_model)
          end
        end

        def hash_with_aggregate_objects(hash_with_foreign_keys, entry, contentful_name, linked_model)
          if hash_with_foreign_keys.has_key?(entry['database_id'].to_s)
            associated_objects = hash_with_foreign_keys[entry['database_id'].to_s].each_with_object([]) do |foreign_key, result|
              aggregated_file = JSON.parse(File.read("#{config.entries_dir}/#{contentful_name}/#{contentful_name}_#{foreign_key}.json"))
              result << aggregated_file[linked_model[:field]]
            end
          end
          associated_objects
        end
      end
    end
  end
end
