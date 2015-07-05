#!/usr/bin/env ruby -w

require 'erb'
require 'fileutils'
require 'set'

xcode_path = '/Applications/Xcode-beta.app'

ios_sdk_path = xcode_path + '/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS9.0.sdk'

ios_uikit_header_path = ios_sdk_path + '/System/Library/Frameworks/UIKit.framework/Headers'
ios_foundation_header_path = ios_sdk_path + '/System/Library/Frameworks/Foundation.framework/Headers'

mac_sdk_path = xcode_path + '/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.11.sdk'

mac_appkit_header_path = mac_sdk_path + '/System/Library/Frameworks/AppKit.framework/Headers'
mac_foundation_header_path = mac_sdk_path + '/System/Library/Frameworks/Foundation.framework/Headers'

output_path = 'MAIKit'

class String
    def to_setter
        selector = self.clone
        selector[0] = selector[0,1].upcase

        return 'set' + selector + ':'
    end
end

class AppleType
    attr_reader :modifiers
    attr_reader :name
    attr_reader :pointer

    @@modifier_tokens = [ 'nullable', 'null_resettable', '__kindof', 'const', 'oneway', 'volatile', 'IBOutlet' ]

    def initialize(str)
        str = str.strip

        @pointer = str.end_with?('*')
        if @pointer
            str = str[0...-1].strip
        end

        str = str.gsub(/\s+\*/, '*')

        @modifiers = []

        tokens = str.gsub(/\s+/m, ' ').strip.split(' ')

        while !tokens.empty?
            token = tokens.shift
            if @@modifier_tokens.include?(token)
                @modifiers.push(token)
            else
                if tokens.empty?
                    @name = token
                else
                    @name = token + ' ' + tokens.join(' ')
                end

                break
            end
        end
    end

    def is_block?
        return self.name.include?("^")
    end

    def to_s
        str = ''

        if self.modifiers.length > 0
            components = self.modifiers.dup
            components.push(self.name)

            str = components.join(' ')
        else
            str = self.name
        end

        if self.pointer
            str += '*'
        end

        return str
    end

    def cast_string
        str = ''

        name = self.name

        if (name == 'IBAction' || name == 'IBOutlet')
            name = 'void'
        end

        if self.modifiers.length > 0
            components = self.modifiers.dup.select{ | modifier |
                !modifier.include?('null') && !modifier.include?('oneway') && !modifier.include?('IBOutlet')
            }
            components.push(name)

            str = components.join(' ')
        else
            str = name
        end

        if self.pointer
            str += '*'
        end

        return str
    end

    def is_int?
        return self.name == 'NSUInteger' || self.name == 'NSInteger' || self.name == 'unsigned int' || self.name == 'int'
    end

    def is_enum?()
        return self.name.start_with?('MAI') && !self.pointer
    end

    def convert_to(prefix)
        @name = prefix + self.name[2..-1]
    end

    def convert_to_mai_type(mai_classes, mai_protocols, mai_enums)
        class_name = self.name

        if class_name.start_with?("NS") or class_name.start_with?("UI")
            replaced_name = "MAI" + class_name[2..-1]

            if mai_enums.include?(replaced_name)
                self.convert_to('MAI')
            else
                mai_classes.keys.each do | mai_class_name |
                    if replaced_name.split(' ').include? mai_class_name
                        self.convert_to('MAI')
                        break
                    end
                end
            end
        end

        mai_protocols.each do | mai_protocol_name, mai_protocol |
            ns_protocol_name = "NS" + mai_protocol_name[3..-1]
            ui_protocol_name = "UI" + mai_protocol_name[3..-1]

            name = self.name

            name.gsub!(/\b#{ns_protocol_name}\b/, mai_protocol_name)
            name.gsub!(/\b#{ui_protocol_name}\b/, mai_protocol_name)

            @name = name
        end

        mai_classes.each do | mai_class_name, mai_class |
            ns_class_name = "NS" + mai_class_name[3..-1]
            ui_class_name = "UI" + mai_class_name[3..-1]

            name = self.name

            name.gsub!(/\b#{ns_class_name}\b/, mai_class_name)
            name.gsub!(/\b#{ui_class_name}\b/, mai_class_name)

            @name = name
        end

        @name = @name.gsub(/\bNSRect\b/, 'CGRect')
        @name = @name.gsub(/\bNSPoint\b/, 'CGPoint')
        @name = @name.gsub(/\bNSRect\b/, 'CGRect')
    end

    def <=>(other)
        if self.modifiers.length == 0 && other.modifiers.length == 0
            if self.is_int? && other.is_enum?
                return 0
            elsif self.is_enum? && other.is_int?
                return 0
            end
        end

        result = (self.modifiers.sort <=> other.modifiers.sort)
        if result != 0
            return result
        end

        result = (self.name <=> other.name)
        if result != 0
            return result
        end

        result = (self.pointer <=> other.pointer)
        if result != 0
            if self.pointer
                return 1
            else
                return -1
            end
        end

        return 0

    end

    def ==(other)
        return (self <=> other) == 0
    end
end

class AppleInterface
    attr_reader :name
    attr_reader :methods
    attr_reader :properties
    attr_reader :protocols

    attr_accessor :ios_name
    attr_accessor :mac_name
    attr_accessor :ios_methods
    attr_accessor :mac_methods
    attr_accessor :ios_properties
    attr_accessor :mac_properties

    def initialize(name)
        @name           = name
        @methods        = {}
        @properties     = {}
        @protocols      = []
        @ios_methods    = nil
        @mac_methods    = nil
        @ios_properties = nil
        @mac_properties = nil
    end

    def update_types(mai_classes, mai_protocols, mai_enums)
        self.methods.each do | method_name, method|
            method.update_types(mai_classes, mai_protocols, mai_enums)
        end

        self.properties.each do | property_name, property |
            property.update_types(mai_classes, mai_protocols, mai_enums)
        end

        replaced_protocols = []
        self.protocols.each do | protocol |
            mai_protocol_name = 'MAI' + protocol[2...protocol.length]
            if mai_protocols.include?(mai_protocol_name)
                replaced_protocols.push(mai_protocol_name)
            else
                replaced_protocols.push(protocol)
            end
        end

        @protocols = replaced_protocols
    end

    def add_method(method)
        self.methods[method.name] = method
    end

    def get_method(name)
        return self.methods[name]
    end

    def add_property(property)
        self.properties[property.name] = property
    end

    def get_property(name)
        return self.properties[name]
    end

    def add_protocol(protocol)
        self.protocols.push(protocol)
    end

    def contains_protocol(protocol)
        if self.protocols.include?(protocol)
            return true
        end

        return false
    end

    def immediate_protocol_names(foundation_protocols)
        return self.protocols.select{ | protocol |
            (protocol.start_with?('MAI') or foundation_protocols.include?(protocol)) and
            protocol != 'NSObject'
        }
    end

    def protocols_str(foundation_protocols)
        return self.immediate_protocol_names(foundation_protocols).join(',')
    end

    def all_methods(classes)
        return self.methods
    end

    def all_properties(classes)
        return self.properties
    end

end

class AppleClass < AppleInterface
    attr_accessor :superclass

    def initialize(name, superclass = 'NSObject')
        @superclass = superclass
        super(name)
    end

    def all_methods(classes)
        methods = {}
        methods = methods.merge(self.methods)

        superclass_name = self.superclass

        while superclass_name != nil and classes[superclass_name] != nil and superclass_name != 'NSObject'
            superclass = classes[superclass_name]
            methods = methods.merge(superclass.methods)
            superclass_name = superclass.superclass
        end

        return methods
    end

    def all_properties(classes)
        properties = {}
        properties = properties.merge(self.properties)

        superclass_name = self.superclass

        while superclass_name != nil and classes[superclass_name] != nil and superclass_name != 'NSObject'
            superclass = classes[superclass_name]
            properties = properties.merge(superclass.properties)
            superclass_name = superclass.superclass
        end

        return properties
    end

    def root_class(classes)
        superclass_name = self.superclass

        while superclass_name != nil and superclass_name != 'NSObject'
            if classes[superclass_name] == nil
                return superclass_name
            else
                superclass = classes[superclass_name]
                superclass_name = superclass.superclass
            end
        end

        return 'NSObject'
    end

end

class AppleMethod
    include Comparable

    attr_reader   :prefix
    attr_reader   :name
    attr_reader   :return_type
    attr_reader   :argument_types
    attr_reader   :argument_names
    attr_accessor :designated_initializer
    attr_accessor :ns_unavailable
    attr_accessor :ns_required

    def initialize(
        prefix,
        name,
        return_type,
        argument_types,
        argument_names,
        designated_initializer,
        ns_unavailable,
        ns_required
    )
        @prefix                 = prefix
        @name                   = name
        @return_type            = return_type
        @argument_types         = argument_types
        @argument_names         = argument_names
        @designated_initializer = designated_initializer
        @ns_unavailable         = ns_unavailable
        @ns_required            = ns_required
    end

    def self.parse(line, ns_required)
        match = /([\-|\+])\s*\(([\w\s\*\(\)\^]+)\)\s*(\w+)/.match(line)

        if match != nil

            prefix      = match[1]
            return_type = match[2].gsub(/\s+\*/, '*')
            first_arg   = match[3]
            name        = nil

            match = line.scan(/(\w+)\s*:\s*\(([\w\s\*\,\(\^\)\<\>\[\]]+)\)\s*(\b(?!(NS|UI)_)\w+)\s*/)
            method_components = []
            argument_types = []
            argument_names = []

            for submatch in match
                method_components.push(submatch[0])
                argument_types.push(AppleType.new(submatch[1]))
                argument_names.push(submatch[2])
            end

            if method_components.length > 0
                name = method_components.join(":") + ":"
            else
                name = first_arg
            end

            designated_initializer = false
            if /NS_DESIGNATED_INITIALIZER/.match(line) != nil
                designated_initializer = true
            end

            ns_unavailable = false
            if /NS_UNAVAILABLE/.match(line) != nil
                ns_unavailable = true
            end

            return AppleMethod.new(
                prefix,
                name,
                AppleType.new(return_type),
                argument_types,
                argument_names,
                designated_initializer,
                ns_unavailable,
                ns_required
            )
        end

        return nil
    end

    def is_initializer(cls)
        return self.prefix == '-' && self.name.start_with?('init') &&
            ((self.return_type.pointer && self.return_type.name == cls) ||
                (self.return_type.name == 'instancetype'))
    end

    def is_convenience_constructor(cls)
        return self.prefix == '+' &&
            ((self.return_type.pointer && self.return_type.name == cls) ||
                (self.return_type.name == 'instancetype'))
    end

    def to_s
        str_value  = ''
        components = name.split(':')

        if (components.length > 1 || name.end_with?(':'))
            parts = []

            for i in 0...components.length
                component     = components[i]
                argument_type = self.argument_types[i].to_s
                argument_name = self.argument_names[i]

                parts.push(component + ':(' + argument_type + ')' + argument_name)
            end

            str_value = parts.join(' ')
        else
            str_value = self.name
        end

        str_value = self.prefix + '(' + self.return_type.to_s + ')' + str_value

        return str_value
    end

    def method_call
        method_call = ''
        components = self.name.split(':')

        if self.name.end_with?(':') && components.length != self.argument_names.length
            raise "#{components.length} arguments required, but #{self.argument_names.length} for #{self.name}"
        end

        for i in 0...components.length
            component = components[i]
            if name.end_with?(':')
                arg = self.argument_names[i]
                if self.argument_types[i].is_block?
                    method_call += " #{component}:(id)#{arg}"
                else
                    method_call += " #{component}:#{arg}"
                end
            else
                method_call += " #{component}"
            end
        end

        return method_call
    end

    def update_types(mai_classes, mai_protocols, mai_enums)
        @return_type.convert_to_mai_type(mai_classes, mai_protocols, mai_enums)
        @argument_types.each do | argument_type |
            argument_type.convert_to_mai_type(mai_classes, mai_protocols, mai_enums)
        end
    end

    def contains_protocol(protocol)
        if self.return_type.name.include?('<' + protocol + '>')
            return true
        end

        self.argument_types.each do | argument_type |
            if argument_type.name.include?('<' + protocol + '>')
                return true
            end
        end

        return false

    end

    def <=>(other)
        result = (self.prefix <=> other.prefix)
        if result != 0
            return result
        end

        result = (self.name <=> other.name)
        if result != 0
            return result
        end

        result = (self.return_type.name <=> other.return_type.name)
        if result != 0
            return result
        end

        result = self.argument_types.length <=> other.argument_types.length
        if result != 0
            return result
        end

        self.argument_types.zip(other.argument_types).each do | type1, type2 |
            result = (type1 <=> type2)
            if result != 0
                return result
            end
        end

        return 0
    end
end

class AppleProperty
    attr_reader   :type
    attr_reader   :name
    attr_reader   :nullability
    attr_accessor :readonly
    attr_accessor :ns_required

    READONLY        = 'readonly'
    NULLABLE        = 'nullable'
    NULL_RESETTABLE = 'null_resettable'

    def initialize(
        type,
        name,
        nullability,
        readonly,
        setter,
        getter,
        ns_required
    )
        @type             = type
        @name             = name
        @nullability      = nullability
        @readonly         = readonly
        @setter           = setter
        @getter           = getter
        @ns_required      = ns_required
    end

    def self.parse(line, ns_required)
        nullability      = nil
        readonly         = false

        line.gsub!(/\/\*.+\*\//, '')

        match = /@property\s*(\(([^)]*)\)*)*\s*([\w\s\<\>\*\,\^]+)(\*\s*|\s+)(\b(?!(NS|UI)_)\w+)/.match(line)

        if match != nil
            attributes = ''
            if match[2] != nil
                attributes = match[2].delete(' ')
            end
            type       = match[3].gsub(/\s+\*/, '*').strip
            pointer    = match[4].strip == '*'
            name       = match[5]
            setter     = nil
            getter     = nil

            if pointer
                type = type + '*'
            end

            for attribute in attributes.split(',')
                if [ NULLABLE, NULL_RESETTABLE ].include?(attribute)
                    nullability = attribute
                elsif [ READONLY ].include?(attribute)
                    readonly = true
                else
                    submatch = /setter\s*=\s*([^\s]+)/.match(attribute)

                    if submatch != nil
                        setter = submatch[1]
                    end

                    submatch = /getter\s*=\s*([^\s]+)/.match(attribute)

                    if submatch != nil
                        getter = submatch[1]
                    end
                end
            end

            return AppleProperty.new(
                AppleType.new(type),
                name,
                nullability,
                readonly,
                setter,
                getter,
                ns_required
            )

        end

        return nil

    end

    def to_s
        str_value = '@property('

        values = []

        if self.readonly
            values.push(READONLY)
        end

        if self.nullability != nil
            values.push(self.nullability)
        end
        if self.setter != nil
            values.push('setter=' + self.setter)
        end

        if self.getter != nil
            values.push('getter=' + self.getter)
        end

        if not values.empty?
            str_value = str_value + values.join(', ')
        end

        str_value = str_value + ') ' + self.type.to_s + ' ' + self.name

        return str_value
    end

    def update_types(mai_classes, mai_protocols, mai_enums)
        @type.convert_to_mai_type(mai_classes, mai_protocols, mai_enums)
    end

    def getter
        return @getter || self.name
    end

    def setter
        if self.readonly
            return nil
        end

        return @setter || self.name.to_setter
    end

    def contains_protocol(protocol)
        if self.type.name.include?('<' + protocol + '>')
            return true
        end

        return false
    end

    def <=>(other)

        result = (self.type <=> other.type)
        if result != 0
            return result
        end

        result = (self.name <=> other.name)
        if result != 0
            return result
        end

        result = (self.nullability <=> other.nullability)
        if result != 0
            return result
        end

        result = (self.readonly <=> other.readonly)
        if result != 0
            if self.readonly
                return 1
            else
                return -1
            end
        end

        result = (self.getter <=> other.getter)
        if result != 0
            return result
        end

        result = (self.setter <=> other.setter)
        if result != 0
            return result
        end

        if result != 0
            return result
        end

        return 0
    end

end

class AppleEnum
    attr_reader :macro
    attr_reader :type
    attr_reader :name
    attr_reader :members

    @@mai_substitutions = {
        'MAITextStorageEditedOptions' => 'MAITextStorageEditActions'
    }

    def initialize(macro, type, name)
        @macro   = macro
        @type    = type
        @name    = 'MAI' + name[2...name.length]
        @members = []

        if @@mai_substitutions[@name] != nil
            @name = @@mai_substitutions[@name]
        end
    end

    def add_member(name, value)
        if value != nil
            value = value.gsub('NS', 'MAI').gsub('UI', 'MAI')
        end

        if value == 'MAITableViewRowActionStyleDefault'
            return
        end

        self.members.push({'name' => 'MAI' + name[2...name.length], 'value' => value })
    end

    def remove_member(name)
        @members = self.members.select { | member | member['name'] != name }
    end

    def has_member?(name)
        return self.members.select { | member | member['name'] == name }.length > 0
    end

    def member_names
        return self.members.map { | member | member['name'] }
    end

    def <=>(other)
        result = (self.type <=> other.type)
        if result != 0
            return result
        end

        result = (self.name <=> other.name)
        if result != 0
            return result
        end

        return self.members.map { | member | member['name'] } <=> other.members.map { | member | member['name'] }
    end

    def to_s
        str_value  = 'typedef ' + self.macro + '(' + self.type.to_s + ', ' + self.name + ") {\n"
        str_value += self.members.map { | member |
            member['value'] ? "#{member['name']} = #{member['value']}" : member['name']
        }.join(",\n")
        str_value += "\n};\n\n"

        return str_value
    end

end

def remove_comments!(str, comment_start='/*', comment_end='*/')
    while start_idx = str.index(comment_start)
        end_idx = str.index(comment_end, start_idx + comment_start.length) + comment_end.length - 1
        str[start_idx .. end_idx] = ""
    end

    return str
end

def parse_headers(header_path)
    classes   = {}
    protocols = {}
    enums     = {}

    Dir.foreach(header_path) do | filename |
        current_interface = nil
        current_enum = nil
        ns_required = false
        deprecated = false

        filename = header_path + '/' + filename

        if File.directory?(filename)
            next
        end

        contents = File.read(filename)
        remove_comments!(contents)

        partial_line = ''

        contents.split("\n").each do | line |

            if line.strip.start_with?('//')
                next
            end

            index = line.index('//')
            if index != nil
                line = line[0...index]
            end

            if /@required/.match(line) != nil
                ns_required = true
            end

            if /@optional/.match(line) != nil
                ns_required = false
            end

            if /NS_DEPRECATED/.match(line) != nil
                deprecated = true
            end

            match = /@interface\s+(\w+)\s*:\s*(\w+)\s*(\<(.+)\>)*/.match(line)
            if match != nil

                class_name = match[1]
                superclass = match[2]

                protocols_str = match[4]

                current_interface = AppleClass.new(class_name, superclass)

                if protocols_str != nil
                    protocols_str.split(',').each do | protocol_str |
                        protocol_str = protocol_str.strip
                        if !deprecated
                            current_interface.add_protocol(protocol_str)
                        end
                        deprecated = false
                    end
                end

                classes[class_name] = current_interface
            end

            match = /@interface\s+(\w+)\s*\((\w+)\)/.match(line)
            if match != nil
                class_name = match[1]
                category_name = match[2]

                if !category_name.include?('Protected')
                    current_interface = classes[class_name]
                end
            end

            match = /@protocol\s*(\w+)\s*(\<(.+)\>)*/.match(line)

            if match != nil
                protocol_name = match[1]
                current_interface = protocols[protocol_name]

                protocols_str = match[3]

                current_interface = AppleInterface.new(protocol_name)
                ns_required = false

                if protocols_str != nil
                    protocols_str.split(',').each do | protocol_str |
                        protocol_str = protocol_str.strip
                        if !deprecated
                            current_interface.add_protocol(protocol_str)
                        end
                        deprecated = false
                    end
                end

                protocols[protocol_name] = current_interface
            end

            match = /(NS_ENUM|NS_OPTIONS)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)/.match(line)

            if match != nil
                if line.start_with?('#define')
                    next
                end

                macro = match[1]
                type  = match[2]
                name  = match[3]

                current_enum = AppleEnum.new(macro, AppleType.new(type), name)
                enums[current_enum.name] = current_enum;
                next
            end

            if current_enum != nil and line.strip[0] == '{'
                next
            end

            if current_enum != nil and line.strip[0] == '}'
                current_enum = nil
            end

            match = /@end/.match(line)
            if match != nil
                current_interface = nil
            end

            if current_interface != nil
                method = AppleMethod.parse(line, ns_required)
                if method != nil
                    if /;/.match(line) == nil
                        partial_line = line
                        next
                    end

                    if !deprecated
                        current_interface.add_method(method)
                    end
                end
                deprecated = false

                property = AppleProperty.parse(line, ns_required)
                if property != nil && !deprecated
                    current_interface.add_property(property)
                end
                deprecated = false
            end

            partial_line = ''

            if current_enum != nil
                deprecated = false

                if line != nil and line.strip.length == 0
                    next
                end

                line = line.strip.split('//')[0]

                if line != nil and line.strip.length == 0
                    next
                end

                line = line.gsub(',', '')

                if line.start_with?('/*') or line.start_with?('*')
                    next
                end

                components = line.split('=')

                subcomponents = components[0].split

                if components.length > 1
                    current_enum.add_member(subcomponents[0].strip, components[1].strip)
                else
                    current_enum.add_member(subcomponents[0], nil)
                end
            end
        end
    end

    return classes, protocols, enums

end

def merge_methods_into_properties(methods, input_properties, output_properties)
    input_properties.each do | property_name, property |
        getter = property.getter
        setter = property.setter

        match = false

        if methods.include?(getter)
            if property.readonly
                match = setter == nil
            elsif methods.include?(setter)
                match = true
            end
        end

        if match
            match = output_properties.include?(property_name)
        end

        if match
            type = property.type
            if methods[getter].return_type == type and (property.readonly or methods[setter].argument_types[0] == type)
                output_properties[property_name] = property
            end
        end

        if methods.include?(getter)
            methods.delete(getter)
        end

        if methods.include?(setter)
            methods.delete(setter)
        end

    end
end

def create_mai_enums(ios_enums, mac_enums)
    mai_enums = {}

    ios_enums.each do | ios_enum_name, ios_enum |
        mac_enum = mac_enums[ios_enum_name]
        if mac_enum != nil
            ios_enum.member_names.each do | member_name |
                if (!mac_enum.has_member?(member_name))
                    ios_enum.remove_member(member_name)
                end
            end
        end
    end

    mac_enums.each do | mac_enum_name, mac_enum |
        ios_enum = ios_enums[mac_enum_name]
        if ios_enum != nil
            mac_enum.member_names.each do | member_name |
                if (!ios_enum.has_member?(member_name))
                    mac_enum.remove_member(member_name)
                end
            end
        end
    end


    ios_enums.each do | ios_enum_name, ios_enum |
        mac_enum = mac_enums[ios_enum_name]
        if mac_enum != nil
            if (ios_enum <=> mac_enum) == 0 && !ios_enum.members.empty?
                mai_enums[ios_enum_name] = ios_enum
            end
        end
    end

    return mai_enums
end

def combine_interfaces(ios_interfaces, mac_interfaces, ios_interface, mac_interface, mai_interface, combine_methods_into_properties)
    ios_methods = ios_interface.all_methods(ios_interfaces)
    mac_methods = mac_interface.all_methods(mac_interfaces)

    ios_properties = ios_interface.all_properties(ios_interfaces)
    mac_properties = mac_interface.all_properties(mac_interfaces)

    if combine_methods_into_properties
        merge_methods_into_properties(mac_methods, ios_properties, mac_properties)
        merge_methods_into_properties(ios_methods, mac_properties, ios_properties)
    end

    mai_interface.ios_methods = ios_methods
    mai_interface.mac_methods = mac_methods

    mai_interface.ios_properties = ios_properties
    mai_interface.mac_properties = mac_properties

    ios_methods.each do | method_name, ios_method |
        if mac_methods.include?(method_name)
            mac_method = mac_methods[method_name]

            if (ios_method <=> mac_method) == 0
                ios_method.designated_initializer ||= mac_method.designated_initializer
                ios_method.ns_unavailable ||= mac_method.ns_unavailable
                ios_method.ns_required ||= mac_method.ns_required
                mai_interface.add_method(ios_method)
            end
        end
    end

    ios_properties.each do | property_name, ios_property |
        if mac_properties.include?(property_name)
            mac_property = mac_properties[property_name]

            if (ios_property <=> mac_property) == 0
                ios_property.ns_required ||= mac_property.ns_required
                ios_property.readonly ||= mac_property.readonly
                mai_interface.add_property(ios_property)
            end
        end
    end

    ios_interface.protocols.each do | ios_protocol |
        if mac_interface.contains_protocol(ios_protocol)
            mai_interface.add_protocol(ios_protocol)
        end
    end
end

def create_mai_interfaces(ios_interfaces, mac_interfaces, cls)
    mai_interfaces = {}

    ios_interfaces.each do | ios_interface_name, ios_interface |
        if ios_interface_name.start_with?('UI') or ios_interface_name.start_with?('NS')
            mac_interface_name = 'NS' + ios_interface_name[2...ios_interface_name.length]

            if mac_interfaces.include?(mac_interface_name)
                mai_interface_name = 'MAI' + mac_interface_name[2...mac_interface_name.length]
                mai_interface = cls.new(mai_interface_name)

                mai_interfaces[mai_interface_name] = mai_interface
            end
        end
    end

    return mai_interfaces
end

def populate_mai_interfaces(ios_interfaces, mac_interfaces, mai_interfaces, combine_methods_into_properties)
    ios_interfaces.each do | ios_interface_name, ios_interface |
        if ios_interface_name.start_with?('UI') or ios_interface_name.start_with?('NS')
            mac_interface_name = 'NS' + ios_interface_name[2...ios_interface_name.length]

            if mac_interfaces.include?(mac_interface_name)
                ios_interface = ios_interfaces[ios_interface_name]
                mac_interface = mac_interfaces[mac_interface_name]

                mai_interface_name = 'MAI' + mac_interface_name[2...mac_interface_name.length]
                mai_interface = mai_interfaces[mai_interface_name]

                if ios_interface.respond_to?(:root_class) and mai_interface.respond_to?(:superclass)
                    mai_interface.superclass = ios_interface.root_class(ios_interfaces)
                end

                mai_interface.ios_name = ios_interface_name
                mai_interface.mac_name = mac_interface_name

                combine_interfaces(ios_interfaces, mac_interfaces, ios_interface, mac_interface, mai_interface, combine_methods_into_properties)
            end
        end
    end

    return mai_interfaces
end

def create_mai_foundation_protocols(ios_foundation_protocols, mac_foundation_protocols)
    mai_foundation_protocols = {}

    mac_foundation_protocols.each do | mac_protocol_name, mac_protocol |
        if ios_foundation_protocols.include?(mac_protocol_name)
            mai_foundation_protocols[mac_protocol_name] = mac_protocol
        end
    end

    return mai_foundation_protocols
end

def write_enum_header(mai_enums, output_path)
    enum_header_file = File.open(File.join(output_path, "MAIEnums.h"), "wb")

    mai_enums.each do | mai_enum_name, mai_enum |
        enum_header_file.write(mai_enum.to_s)
    end
end

ios_foundation_classes, ios_foundation_protocols, ios_foundation_enums = parse_headers(ios_foundation_header_path)

ios_classes, ios_protocols, ios_enums = parse_headers(ios_uikit_header_path)

mac_foundation_classes, mac_foundation_protocols, mac_foundation_enums = parse_headers(mac_foundation_header_path)

mac_classes, mac_protocols, mac_enums = parse_headers(mac_appkit_header_path)

mai_foundation_protocols = create_mai_foundation_protocols(ios_foundation_protocols, mac_foundation_protocols)

mai_classes = create_mai_interfaces(ios_classes, mac_classes, AppleClass)

mai_protocols = create_mai_interfaces(ios_protocols, mac_protocols, AppleInterface)

mai_enums = create_mai_enums(ios_enums, mac_enums)

ios_classes.values.each do | ios_class |
    ios_class.update_types(mai_classes, mai_protocols, mai_enums)
end

mac_classes.values.each do | mac_class |
    mac_class.update_types(mai_classes, mai_protocols, mai_enums)
end

ios_protocols.values.each do | ios_protocol |
    ios_protocol.update_types(mai_classes, mai_protocols, mai_enums)
end

mac_protocols.values.each do | mac_protocol |
    mac_protocol.update_types(mai_classes, mai_protocols, mai_enums)
end

populate_mai_interfaces(ios_classes, mac_classes, mai_classes, true)

populate_mai_interfaces(ios_protocols, mac_protocols, mai_protocols, false)

FileUtils.mkdir_p(output_path)

umbrella_header_file = File.open(File.join(output_path, "MAIKit.h"), "wb")

classes_to_import = mai_classes.keys
protocols_to_import = mai_protocols.keys

umbrella_header_template_string = File.open('umbrella_header.erb', 'rb').read()
umbrella_header_template = ERB.new(umbrella_header_template_string, nil, '<>')
umbrella_header_file.write(umbrella_header_template.result(binding))

write_enum_header(mai_enums, output_path)

header_template_string = File.open("header.erb", "rb").read()
implementation_template_string = File.open("implementation.erb", "rb").read()

mai_classes.keys.sort.each do | mai_class_name |
    mai_class = mai_classes[mai_class_name]

    header_filename         = File.join(output_path, mai_class_name + ".h")
    implementation_filename = File.join(output_path, mai_class_name + ".m")

    header_file         = File.open(header_filename,         "wb")
    implementation_file = File.open(implementation_filename, "wb")

    header_template = ERB.new(header_template_string, nil, '<>')
    header_file.write(header_template.result(binding))

    implementation_template = ERB.new(implementation_template_string, nil, '<>')
    implementation_file.write(implementation_template.result(binding))
end

mai_protocols.keys.sort.each do | mai_protocol_name |
    mai_protocol = mai_protocols[mai_protocol_name]

    protocol_filename = File.join(output_path, mai_protocol_name + ".h")
    protocol_file = open(protocol_filename, "wb")

    protocol_template_string = File.open('protocol.erb', 'rb').read()
    protocol_template = ERB.new(protocol_template_string, nil, '<>')
    protocol_file.write(protocol_template.result(binding))
end
