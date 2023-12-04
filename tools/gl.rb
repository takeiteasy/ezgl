=begin
gl.rb -- https://github.com/takeiteasy/cwcGL

The MIT License (MIT)

Copyright (c) 2022 George Watson

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software,
and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
=end

require "nokogiri"
require "net/http"

# Download required files if needed
xml = ["https://registry.khronos.org/EGL/api/KHR/khrplatform.h",
       "https://raw.githubusercontent.com/KhronosGroup/OpenGL-Registry/main/xml/gl.xml"]
xml.each do |x|
  xp = "tools/" + File.basename(x)
  next if File.exist? xp
  resp = Net::HTTP.get_response URI(x)
  abort "ERROR: #{resp.code}" unless resp.is_a? Net::HTTPSuccess
  File.write xp, resp.body
end

# Parse gl.xml with Nokogiri
doc = Nokogiri::XML File.open("tools/gl.xml") do |config|
  config.options = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NOBLANKS
end

# Parse <types>
types = doc.xpath("//types").children.reject { |c| c.class.to_s == "Nokogiri::XML::Comment" }.map do |t|
  html = t.inner_html.gsub "<apientry></apientry>", "APIENTRY"
  /<name>(?<name>.*)<\/name>/ =~ html
  [name, t.text]
end.to_h.delete_if { |k, v| k.nil? }
# Parse <enums>
enums = doc.xpath("//enums").children.map { |e| [e.attr('name'), e.attr('value')] }.to_h
# Parse <commands>
commands = doc.xpath("//commands").children.map do |f|
  parts = {:params => []}
  name = nil
  f.children.each do |ff|
    case ff.to_s
    when /^<proto/
      fff = ff.children.to_a
      name = fff.pop.text
      parts[:result] = fff.map { |ffff| ffff.text.strip }.join " "
    when /^<param/
      parts[:params] << ff.children.to_a.map { |ffff| ffff.text.strip }.join(" ")
    end
  end
  parts[:params] = ["void"] if parts[:params].empty?
  [name, parts]
end.to_h

puts <<HEADER
#define __gl_glcorearb_h_ 1  /* Khronos core */
#define __gl_glext_h_ 1      /* Khronos compatibility */
#define __gl_h_ 1            /* Windows/Linux */
#define __GL_H__ 1           /* Windows */
#define __gl3_h_ 1           /* Mac */

#if defined(_WIN32) && !defined(APIENTRY) && !defined(__CYGWIN__) && !defined(__SCITECH_SNAP__)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN 1
#endif
#include <windows.h>
#define APIENTRY __stdcall
#endif

#ifndef APIENTRY
#define APIENTRY
#endif
#ifndef APIENTRYP
#define APIENTRYP APIENTRY *
#endif
#ifndef GLAPI
#if defined(GLAD_GLAPI_EXPORT)
#if defined(_WIN32) || defined(__CYGWIN__)
#if defined(GLAD_GLAPI_EXPORT_BUILD)
#if defined(__GNUC__)
#define GLAPI __attribute__ ((dllexport)) extern
#else
#define GLAPI __declspec(dllexport) extern
#endif
#else
#if defined(__GNUC__)
#define GLAPI __attribute__ ((dllimport)) extern
#else
#define GLAPI __declspec(dllimport) extern
#endif
#endif
#elif defined(__GNUC__) && defined(GLAD_GLAPI_EXPORT_BUILD)
#define GLAPI __attribute__ ((visibility ("default"))) extern
#else
#define GLAPI extern
#endif
#else
#define GLAPI extern
#endif
#endif

#if !defined(CWCGL_VERSION)
#define CWCGL_VERSION 1000
#endif
HEADER

# Find <feature>, remove any unused gl versions
features = doc.xpath("//feature").select { |f| f.attr('name') =~ /^GL_VERSION_\d_\d$/ }

# Print out version macros
features.each do |f|
  maj, min = f.attr('number').split('.')
  puts "#define #{f.attr 'name'} #{maj}0#{min}0"
end

# Parse and print khrplatform.h
khr = File.readlines("tools/khrplatform.h").map { |l| l.rstrip }[4..-2]
puts "\n/* khrplatform.h -- [https://registry.khronos.org/EGL/api/KHR/khrplatform.h]", khr.join("\n"), "/* end of khrplatform.h */", ""

# Format features for each gl version
defined = []
functions = {}
features.each do |f|
  puts "#if CWCGL_VERSION >= #{f.attr 'name'}"
  ver = f.attr 'number'
  functions[ver] = []

  f.children.each do |ff|
    ff.children.each do |fff|
      name = fff.attr("name")
      if fff.to_s =~ /^<command/
        commands[name][:params].each do |p|
          t = p.split(" ").select! { |pp| pp =~ /GL/ }
          unless t.nil?
            t.each do |tt|
              unless defined.include? tt
                puts types[tt]
                defined << tt
              end
            end
          end
        end
      end
    end
  end

  f.children.each do |ff|
    ff.children.each do |fff|
      name = fff.attr("name")
      next if defined.include? name
      case fff.to_s
      when /^<type/
        puts types[name]
      when /^<enum/
        puts "#define #{name} #{enums[name]}"
      when /^<command/
        proc = "PFN#{name.upcase}PROC"
        puts "typedef #{commands[name][:result]} (APIENTRYP #{proc})(#{commands[name][:params].join ', '});"
        puts "#define #{name} __#{name}"
        functions[ver].append [proc, name]
      end
      defined << name
    end
  end
  puts "#endif"
  puts
end

# Store functions in macros for later
functions.each do |k, v|
  v.each do |vv|
    puts "\tX(#{vv[0]}, #{vv[1]}) \\"
  end
end

# Define functions
puts "", "#define X(T, N) extern T __##N;"
functions.each do |k, v|
  maj, min = k.split '.'
  puts "#if CWCGL_VERSION >= GL_VERSION_#{maj}_#{min}"
  puts "GL_FUNCTIONS_#{maj}_#{min}"
  puts "#endif"
end
puts "#undef X", ""

commands.each do |k, v|
  argsVoid = (v[:params].length == 1 and v[:params][0] == "void")
  returnsVoid = v[:result] == "void"
  params = v[:params].join ", "
  returnValue = returnsVoid ? "" : ", #{v[:result]}* return_value"
  puts "EXPORT void cwc#{k}(GLcontext *context#{params == "void" ? "" : ", " + params}#{returnValue});"
end

puts "", "#define X(T, N) T __##N = (T)((void*)0);"
functions.each do |k, v|
  maj, min = k.split '.'
  puts "#if CWCGL_VERSION >= GL_VERSION_#{maj}_#{min}"
  puts "GL_FUNCTIONS_#{maj}_#{min}"
  puts "#endif"
end
puts "#undef X", ""

puts "typedef enum {"
commands.each do |k, _|
  puts "    cwc#{k}Command,"
end
puts "} cwcglCommandType;", ""

puts "typedef struct {"
puts "    void* data;"
puts "    cwcglCommandType type;"
puts "} cwcglCommand;", ""

commands.each do |k, v|
  argsVoid = (v[:params].length == 1 and v[:params][0] == "void")
  returnsVoid = v[:result] == "void"
  if not argsVoid
    puts "typedef struct {"
    v[:params].each do |vv|
      puts "    #{vv};"
    end
    unless returnsVoid
      puts "    #{v[:result]} return_value;"
    end
    puts "} cwc#{k}CommandData;", ""
  else
    if not returnsVoid
      puts "typedef struct {"
      puts "    #{v[:result]} return_value;"
      puts "} cwc#{k}CommandData;", ""
    end
  end
  params = v[:params].join ", "
  noParams = params == "void"
  returnValue = returnsVoid ? "" : ", #{v[:result]}* return_value"
  puts "void cwc#{k}(GLcontext *context#{noParams ? "" : ", " + params}#{returnValue}) {"
  puts "    cwcglCommand* command = malloc(sizeof(cwcglCommand);"
  hasParams = (not noParams or (not returnsVoid and argsVoid))
  if hasParams
    puts "    cwc#{k}CommandData* data = malloc(sizeof(cwc#{k}CommandData));"
    if not argsVoid
      v[:params].each do |vv|
        vvv = vv.split(' ')[-1]
        puts "    data->#{vvv} = #{vvv};"
      end
    end
    unless returnsVoid
      puts "    data->return_value = return_value;"
    end
  end
  puts "    command->type = cwc#{k}Command;"
  if hasParams
    puts "    command->data = data;"
  else
    puts "    command->data = NULL;"
  end
  puts "    cwcglPushCommand(context, command);"
  puts "}", ""
end

puts "void cwcglFreeCommand(cwcglCommand* command) {"
puts "    switch (command->type)"
commands.each do |k, v|
  argsVoid = v[:params].length == 1 and v[:params][0] == "void"
  returnsVoid = v[:result] == "void"
  if not returnsVoid or not argsVoid
    puts "        case cwc#{k}Command:"
  end
end
puts "            free(command->data);"
puts "        default:"
puts "            free(command);"
puts "            break;"
puts "}", ""

puts "void cwcglProcessCommand(cwcglCommand* command) {"
puts "    switch (command->type)"
commands.each do |k, v|
  argsVoid = v[:params].length == 1 and v[:params][0] == "void"
  returnsVoid = v[:result] == "void"
  if argsVoid and returnsVoid
    puts "        case cwc#{k}Command:"
    puts "            #{k}();"
  else
    puts "        case cwc#{k}Command: {"
    puts "            cwc#{k}CommandData* data = (cwc#{k}CommandData*)command->data;"
    params = unless argsVoid
               v[:params].map do |p|
                 "data->" + p.split(" ")[-1]
               end.join ", "
             else
               ""
             end
    unless returnsVoid
      puts "            if (data->return_value)"
      puts "                *(data->return_value) = #{k}(#{params});"
      puts "            else"
      puts "                #{k}(#{params});"
    else
      puts "            #{k}(#{params});"
    end
  end
  puts "            break;"
  if not argsVoid
    puts "        }"
  end
end
puts "        default:"
puts "            abort();"
puts "}", ""
