#!/usr/bin/env ruby -w

require 'fileutils'

xcode_path = '/Applications/Xcode.app'

ios_sdk_path = xcode_path + '/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator8.1.sdk'

ios_uikit_header_path = ios_sdk_path + '/System/Library/Frameworks/UIKit.framework/Headers'
ios_foundation_header_path = ios_sdk_path + '/System/Library/Frameworks/Foundation.framework/Headers'

mac_sdk_path = xcode_path + '/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.10.sdk'

mac_appkit_header_path = mac_sdk_path + '/System/Library/Frameworks/AppKit.framework/Headers'
mac_foundation_header_path = mac_sdk_path + '/System/Library/Frameworks/Foundation.framework/Headers'

output_path = 'output'

ios_classes = {}
mac_classes = {}
mai_classes = {}

class String
    def to_setter
        selector = self.clone
        selector[0] = selector[0,1].upcase

        return 'set' + selector + ':'
    end
end

def compare_types(type1, type2)
    generic_class_types = [ 'id', 'instancetype' ]

    if generic_class_types.include?(type1) and generic_class_types.include?(type2)
        return 0
    elsif generic_class_types.include?(type1) and type2.end_with?('*')
        return 0
    elsif type1.end_with?('*') and generic_class_types.include?(type2)
        return 0
    end

    return type1 <=> type2
end

def mai_class_name(class_name, mai_classes)
    mai_class = class_name

    if class_name == 'NSRect'
        return 'CGRect'
    elsif class_name == 'NSPoint'
        return 'CGPoint'
    elsif class_name == 'NSSize'
        return 'CGSize'
    elsif class_name.start_with?("NS") or class_name.start_with?("UI")
        replaced_name = "MAI" + class_name[2...-1]

        if mai_classes.include?(replaced_name)
            mai_class = replaced_name + '*'
        end
    end

    return mai_class
end

class AppleClass
    attr_reader :name
    attr_reader :superclass
    attr_reader :methods
    attr_reader :properties

    def initialize(name, superclass)
        @name       = name
        @superclass = superclass
        @methods    = {}
        @properties = {}
    end

    def update_types(mai_classes)
        self.methods.each do | method_name, method|
            method.update_types(mai_classes)
        end

        self.properties.each do | property_name, property |
            property.update_types(mai_classes)
        end
    end

    def all_methods(classes)
        methods = {}
        methods = methods.merge(self.methods)

        superclass_name = self.superclass

        while superclass_name != nil and superclass_name != 'NSObject'
            superclass = classes[superclass_name]
            methods = methods.merge(superclass.methods)
            superclass_name = superclass.superclass
        end

        return methods
    end

    def add_method(method)
        self.methods[method.name] = method
    end

    def get_method(name)
        return self.methods[name]
    end

    def all_properties(classes)
        properties = {}
        properties = properties.merge(self.properties)

        superclass_name = self.superclass

        while superclass_name != nil and superclass_name != 'NSObject'
            superclass = classes[superclass_name]
            properties = properties.merge(superclass.properties)
            superclass_name = superclass.superclass
        end

        return properties
    end

    def add_property(property)
        self.properties[property.name] = property
    end

    def get_property(name)
        return self.properties[name]
    end

end

class AppleMethod
    include Comparable

    attr_reader :type
    attr_reader :name
    attr_reader :return_type
    attr_reader :argument_types
    attr_reader :argument_names

    def initialize(type, name, return_type, argument_types, argument_names)
        @type           = type
        @name           = name
        @return_type    = return_type
        @argument_types = argument_types
        @argument_names = argument_names
    end

    def self.parse(line)
        match = /([\-|\+])\s*\(([^\)]+)\)\s*(\w+)/.match(line)

        if match != nil

            type        = match[1]
            return_type = match[2].delete(' ')
            first_arg   = match[3]
            name        = nil

            match = line.scan(/(\w+)\s*:\s*\(([^\)]+)\)\s*(\w+)\s*/)
            method_components = []
            argument_types = []
            argument_names = []

            for submatch in match
                method_components.push(submatch[0])
                argument_types.push(submatch[1])
                argument_names.push(submatch[2])
            end

            if method_components.length > 0
                name = method_components.join(":") + ":"
            else
                name = first_arg
            end

            return AppleMethod.new(type, name, return_type, argument_types, argument_names)
        end

        return nil
    end

    def to_s
        str_value  = ''
        components = name.split(':')

        if (components.length > 1 || name.end_with?(':'))
            parts = []

            for i in 0...components.length
                component     = components[i]
                argument_type = self.argument_types[i]
                argument_name = self.argument_names[i]

                parts.push(component + ':(' + argument_type + ')' + argument_name)
            end

            str_value = parts.join(' ')
        else
            str_value = self.name
        end

        str_value = self.type + '(' + self.return_type + ')' + str_value

        return str_value
    end

    def update_types(mai_classes)
        @return_type = mai_class_name(@return_type, mai_classes)
        @argument_types = @argument_types.map { | argument_type | mai_class_name(argument_type, mai_classes) }
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

        result = (self.return_type <=> other.return_type)
        if result != 0
            return result
        end

        result = (self.argument_types <=> other.argument_types)
        if result != 0
            return result
        end

        return 0
    end

    def is_initializer
        return self.type == '-' && self.name.start_with?('init')
    end
end

class AppleProperty
    attr_reader :type
    attr_reader :name
    attr_reader :memory_semantics
    attr_reader :atomicity
    attr_reader :access

    STRONG    = 'strong'
    WEAK      = 'weak'
    ASSIGN    = 'assign'
    RETAIN    = 'retain'
    ATOMIC    = 'atomic'
    NONATOMIC = 'nonatomic'
    READONLY  = 'readonly'
    READWRITE = 'readwrite'

    def initialize(type, name, memory_semantics, atomicity, access, setter, getter)
        @type             = type
        @name             = name
        @memory_semantics = memory_semantics
        @atomicity        = atomicity
        @access           = access
        @setter           = setter
        @getter           = getter
    end

    def self.parse(line)
        memory_semantics = ASSIGN
        atomicity        = NONATOMIC
        access           = READWRITE

        match = /@property\s*\(([^)]*)\)*\s*([\w\s\<\>]+\s*\**)\s+(\w+)/.match(line)

        if match != nil
            attributes = match[1].delete(' ')
            type       = match[2].delete(' ')
            name       = match[3]
            setter     = nil
            getter     = nil

            for attribute in attributes.split(',')
                if [ STRONG, WEAK, ASSIGN, RETAIN ].include?(attribute)
                    memory_semantics = attribute
                elsif [ READONLY, READWRITE ].include?(attribute)
                    access = attribute
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

           return AppleProperty.new(type, name, memory_semantics, atomicity, access, setter, getter)

        end

        return nil

    end

    def to_s
        str_value = '@property(' + self.atomicity + ', ' + self.access + ', ' + self.memory_semantics

        if @setter != nil
            str_value = str_value + ', setter=' + @setter
        end

        if @getter != nil
            str_value = str_value + ', getter=' + @getter
        end

        str_value = str_value + ') ' + self.type + ' ' + self.name

        return str_value
    end

    def update_types(mai_classes)
        @type = mai_class_name(@type, mai_classes)
    end

    def getter
        return @getter || self.name
    end

    def setter
        if self.readonly?
            return nil
        end

        return @setter || self.name.to_setter
    end

    def readonly?
        return self.access == READONLY
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

        result = (self.getter <=> other.getter)
        if result != 0
            return result
        end

        result = (self.setter <=> other.setter)
        if result != 0
            return result
        end

        result = (self.access <=> other.access)
        if result != 0
            return result
        end

        result = (self.memory_semantics <=> other.memory_semantics)
        if result != 0
            return result
        end

        return 0
    end

end

def parse_headers(container, header_path)
    Dir.foreach(header_path) do | filename |
        current_class = nil

        filename = header_path + '/' + filename

        if File.directory?(filename)
            next
        end

        File.readlines(filename).each do | line |

            match = /@interface\s+(\w+)/.match(line)
            if match != nil

                class_name = match[1]
                current_class = container[class_name]
                superclass = nil

                match = /@interface\s+\w+\s*:\s*(\w+)/.match(line)
                if match != nil
                    superclass = match[1]
                end

                if current_class == nil
                    current_class = AppleClass.new(class_name, superclass)
                    container[class_name] = current_class
                end
            end

            match = /@end/.match(line)
            if match != nil
                current_class = nil
            end

            if current_class != nil
                method = AppleMethod.parse(line)
                if method != nil
                    current_class.add_method(method)
                end

                property = AppleProperty.parse(line)
                if property != nil
                    current_class.add_property(property)
                end
            end
        end
    end
end

def merge_methods_into_properties(methods, input_properties, output_properties)
    input_properties.each do | property_name, property |
        getter = property.getter
        setter = property.setter

        match = false

        if methods.include?(getter)
            if property.readonly?
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
            if methods[getter].return_type == type and (property.readonly? or methods[setter].argument_types[0] == type)
                methods.delete(getter)
                methods.delete(setter)
                output_properties[property_name] = property
            end
        end

    end
end

def method_call_str(name, args)
    method_call = ''
    components = name.split(':')

    if name.end_with?(':') && components.length != args.length
        raise "#{components.length} arguments required, but #{args.length} for #{name}"
    end

    for i in 0...components.length
        component = components[i]
        if name.end_with?(':')
            arg = args[i]
            method_call += " #{component}:#{arg}"
        else
            method_call += " #{component}"
        end
    end

    return method_call
end

def write_initializer(file, name, args, prototype, ios_class_name, mac_class_name, mai_class_name)
    method_call = method_call_str(name, args)

    file.write(prototype + "\n")
    file.write("\{\n")
    file.write("#if TARGET_OS_IPHONE\n")
    file.write("    return (#{mai_class_name}*) [(#{ios_class_name}*) self#{method_call}];\n")
    file.write("#else\n")
    file.write("    return (#{mai_class_name}*) [(#{mac_class_name}*) self#{method_call}];\n")
    file.write("#endif\n")
    file.write("\}\n\n")
end

parse_headers(ios_classes, ios_foundation_header_path)
parse_headers(ios_classes, ios_uikit_header_path)

parse_headers(mac_classes, mac_foundation_header_path)
parse_headers(mac_classes, mac_appkit_header_path)

ios_classes.each do | ios_class_name, ios_class |
    if ios_class_name.start_with?('UI')
        mac_class_name = 'NS' + ios_class_name[2...ios_class_name.length]

        if mac_classes.include?(mac_class_name)
            mai_class_name = 'MAI' + mac_class_name[2...mac_class_name.length]
            mai_class = AppleClass.new(mai_class_name, 'NSObject')
            mai_classes[mai_class_name] = mai_class
        end
    end
end

ios_classes.each do | ios_class_name, ios_class |
    ios_class.update_types(mai_classes)
end

mac_classes.each do | mac_class_name, mac_class |
    mac_class.update_types(mai_classes)
end

ios_class_names = []
mac_class_names_by_ios_class_name = {}
mai_class_names_by_ios_class_name = {}

ios_classes.each do | ios_class_name, ios_class |
    if ios_class_name.start_with?('UI')
        mac_class_name = 'NS' + ios_class_name[2...ios_class_name.length]

        if mac_classes.include?(mac_class_name)
            mai_class_name = 'MAI' + mac_class_name[2...mac_class_name.length]

            ios_class_names.push(ios_class_name)
            mac_class_names_by_ios_class_name[ios_class_name] = mac_class_name
            mai_class_names_by_ios_class_name[ios_class_name] = mai_class_name
        end
    end
end

FileUtils.mkdir_p(output_path)

umbrella_header_file = File.open(File.join(output_path, "MAIKit.h"), "wb")

umbrella_header_file.write("//! Project version number for MAIKit.\n")
umbrella_header_file.write("FOUNDATION_EXPORT double MAIKitVersionNumber;\n\n")

umbrella_header_file.write("//! Project version string for MAIKit.\n")
umbrella_header_file.write("FOUNDATION_EXPORT const unsigned char MAIKitVersionString[];\n\n")

ios_class_names.sort.each do | ios_class_name |
    mac_class_name = mac_class_names_by_ios_class_name[ios_class_name]
    mai_class_name = mai_class_names_by_ios_class_name[ios_class_name]

    ios_class = ios_classes[ios_class_name]
    mac_class = mac_classes[mac_class_name]

    ios_methods = ios_class.all_methods(ios_classes)
    mac_methods = mac_class.all_methods(mac_classes)

    ios_properties = ios_class.all_properties(ios_classes)
    mac_properties = mac_class.all_properties(mac_classes)

    merge_methods_into_properties(mac_methods, ios_properties, mac_properties)
    merge_methods_into_properties(ios_methods, mac_properties, ios_properties)

    mai_methods    = []
    mai_properties = []

    ios_methods.each do | method_name, ios_method |
        if mac_methods.include?(method_name)
            mac_method = mac_methods[method_name]

            if (ios_method <=> mac_method) == 0
                mai_methods.push(ios_method)
            end
        end
    end

    ios_properties.each do | property_name, ios_property |
        if mac_properties.include?(property_name)
            mac_property = mac_properties[property_name]

            if (ios_property <=> mac_property) == 0
                mai_properties.push(ios_property)
            end
        end
    end

    if (not mai_methods.empty?) or (not mai_properties.empty?)
        wrote_init = false

        header_filename         = File.join(output_path, mai_class_name + ".h")
        implementation_filename = File.join(output_path, mai_class_name + ".m")

        header_file         = File.open(header_filename,         "wb")
        implementation_file = File.open(implementation_filename, "wb")

        header_file.write("#import <TargetConditionals.h>\n")
        header_file.write("#if TARGET_OS_IPHONE\n")
        header_file.write("@import UIKit;\n")
        header_file.write("#else\n")
        header_file.write("@import AppKit;\n")
        header_file.write("#endif\n\n")

        mai_class_names_by_ios_class_name.sort.each do | ignored, other_mai_class |
            if mai_class_name != other_mai_class
                header_file.write("@class #{other_mai_class};\n")
            end
        end

        header_file.write("\n")

        header_file.write("@interface #{mai_class_name} : NSObject\n")

        implementation_file.write("#import \"#{mai_class_name}.h\"\n")
        implementation_file.write("@implementation #{mai_class_name}\n\n")
        implementation_file.write("+ (instancetype)allocWithZone:(struct _NSZone *)zone\n")
        implementation_file.write("\{\n")
        implementation_file.write("#if TARGET_OS_IPHONE\n")
        implementation_file.write("    return (#{mai_class_name}*) [#{ios_class_name} alloc];\n")
        implementation_file.write("#else\n")
        implementation_file.write("    return (#{mai_class_name}*)  [#{mac_class_name} alloc];\n")
        implementation_file.write("#endif\n")
        implementation_file.write("\}\n\n")
        implementation_file.write("#if TARGET_OS_IPHONE\n")
        implementation_file.write("-(#{ios_class_name}*) ios\n")
        implementation_file.write("\{\n")
        implementation_file.write("    return (#{ios_class_name}*) self;\n")
        implementation_file.write("\}\n")
        implementation_file.write("#else\n")
        implementation_file.write("-(#{mac_class_name}*) mac\n")
        implementation_file.write("\{\n")
        implementation_file.write("    return (#{mac_class_name}*) self;\n")
        implementation_file.write("\}\n")
        implementation_file.write("#endif\n\n")

        mai_methods.each do | mai_method |
            header_file.write('    ' + mai_method.to_s + ";\n")

            if mai_method.is_initializer
                if mai_method.name == 'init'
                    wrote_init = true
                end

                write_initializer(
                    implementation_file,
                    mai_method.name,
                    mai_method.argument_names,
                    mai_method.to_s,
                    ios_class_name,
                    mac_class_name,
                    mai_class_name
                )
            else
                implementation_file.write(mai_method.to_s + "\n")
                implementation_file.write("\{\n")
                if mai_method.return_type != 'void'
                    implementation_file.write("    #{mai_method.return_type} returnValue;\n")
                    implementation_file.write("    return returnValue;\n")
                end
                implementation_file.write("\}\n\n")
            end
        end

        if not wrote_init
            write_initializer(
                implementation_file,
                'init',
                [],
                '-(instancetype)init',
                ios_class_name,
                mac_class_name,
                mai_class_name
            )
        end

        header_file.write("\n")

        mai_properties.each do | mai_property |
            header_file.write('    ' + mai_property.to_s + ";\n")
        end

        header_file.write("@end\n")
        implementation_file.write("@end\n")

        umbrella_header_file.write("#import \"#{mai_class_name}.h\n")
    end
end
