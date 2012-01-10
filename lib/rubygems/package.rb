# -*- coding: utf-8 -*-
#--
# Copyright (C) 2004 Mauricio Julio Fernández Pradier
# See LICENSE.txt for additional licensing information.
#++

require 'rubygems/security'
require 'rubygems/specification'
require 'rubygems/user_interaction'

class Gem::Package

  include Gem::UserInteraction

  class Error < Gem::Exception; end
  class FormatError < Error
    attr_reader :path

    def initialize message, path = nil
      @path = path

      message << " in #{path}" if path

      super message
    end

  end
  class PathError < Error
    def initialize destination, destination_dir
      super "installing into parent path %s of %s is not allowed" %
              [destination, destination_dir]
    end
  end

  class NonSeekableIO < Error; end
  class ClosedIO < Error; end
  class BadCheckSum < Error; end
  class TooLongFileName < Error; end

  ##
  # Raised when a tar file is corrupt

  class TarInvalidError < Error; end

  # FIX: zenspider said: does it really take an IO?
  # passed to a method called open?!? that seems stupid.
  def self.open(io, mode = "r", signer = nil, &block)
    tar_type = case mode
               when 'w' then TarOutput
               else
                 raise "Unknown Package open mode"
               end

    tar_type.open(io, signer, &block)
  end

  def self.pack(src, destname, signer = nil)
    TarOutput.open(destname, signer) do |outp|
      dir_class.chdir(src) do
        outp.metadata = (file_class.read("RPA/metadata") rescue nil)
        find_class.find('.') do |entry|
          case
          when file_class.file?(entry)
            entry.sub!(%r{\./}, "")
            next if entry =~ /\ARPA\//
            stat = File.stat(entry)
            outp.add_file_simple(entry, stat.mode, stat.size) do |os|
              file_class.open(entry, "rb") do |f|
                os.write(f.read(4096)) until f.eof?
              end
            end
          when file_class.dir?(entry)
            entry.sub!(%r{\./}, "")
            next if entry == "RPA"
            outp.mkdir(entry, file_class.stat(entry).mode)
          else
            raise "Don't know how to pack this yet!"
          end
        end
      end
    end
  end

  ##
  # The files in this package.  This is not the contents of the gem, just the
  # files in the top-level container.

  attr_reader :files

  ##
  # The security policy used for verifying the contents of this package.

  attr_accessor :security_policy

  ##
  # Sets the Gem::Specification to use to build this package.

  attr_writer :spec

  def self.build spec
    gem_file = spec.file_name

    package = new gem_file
    package.spec = spec
    package.build

    gem_file
  end

  ##
  # Creates a new Gem::Package for the file at +gem+.
  #
  # If +gem+ is an existing file in the old format a Gem::Package::Old will be
  # returned.

  def self.new gem
    return super unless Gem::Package == self
    return super unless File.exist? gem

    start = File.read gem, 20

    return super unless start
    return super unless start.include? 'MD5SUM ='

    Gem::Package::Old.new gem
  end

  ##
  # Creates a new package that will read or write to the file +gem+.

  def initialize gem # :notnew:
    @gem   = gem

    @contents = nil
    @digest = Gem::Security::OPT[:dgst_algo]
    @files = nil
    @security_policy = nil
    @spec = nil
    @signer = nil
  end

  ##
  # Adds the files listed in the packages's Gem::Specification to data.tar.gz
  # and adds this file to the +tar+.

  def add_contents tar # :nodoc:
    tar.add_file_signed 'data.tar.gz', 0444, @signer do |io|
      Zlib::GzipWriter.wrap io do |gz_io|
        Gem::Package::TarWriter.new gz_io do |data_tar|
          add_files data_tar
        end
      end
    end
  end

  ##
  # Adds files included the package's Gem::Specification to the +tar+ file

  def add_files tar # :nodoc:
    @spec.files.each do |file|
      stat = File.stat file

      tar.add_file_simple file, stat.mode, stat.size do |dst_io|
        open file, 'rb' do |src_io|
          dst_io.write src_io.read 16384 until src_io.eof?
        end
      end
    end
  end

  ##
  # Adds the package's Gem::Specification to the +tar+ file

  def add_metadata tar # :nodoc:
    metadata = @spec.to_yaml
    metadata_gz = Gem.gzip metadata

    tar.add_file_signed 'metadata.gz', 0444, @signer do |io|
      io.write metadata_gz
    end
  end

  ##
  # Builds this package based on the specification set by #spec=

  def build
    @spec.validate
    @spec.mark_version

    if @spec.signing_key then
      require 'rubygems/security'

      @signer = Gem::Security::Signer.new @spec.signing_key, @spec.cert_chain
      @spec.signing_key = nil
      @spec.cert_chain = @signer.cert_chain.map { |cert| cert.to_s }
    else
      @signer = Gem::Security::Signer.new nil, nil
    end

    open @gem, 'wb' do |gem_io|
      Gem::Package::TarWriter.new gem_io do |gem|
        add_metadata gem
        add_contents gem
      end
    end

    say <<-EOM
  Successfully built RubyGem
  Name: #{@spec.name}
  Version: #{@spec.version}
  File: #{File.basename @spec.cache_file}
EOM
  ensure
    @signer = nil
  end

  ##
  # A list of file names contained in this gem

  def contents
    return @contents if @contents

    verify unless @spec

    @contents = []

    open @gem, 'rb' do |io|
      gem_tar = Gem::Package::TarReader.new io

      gem_tar.each do |entry|
        next unless entry.full_name == 'data.tar.gz'

        open_tar_gz entry do |pkg_tar|
          pkg_tar.each do |contents_entry|
            @contents << contents_entry.full_name
          end
        end

        return @contents
      end
    end
  end

  ##
  # Creates a digest of the TarEntry +entry+ from the digest algorithm set by
  # the security policy.

  def digest entry # :nodoc:
    digester = @digest.new

    digester << entry.read(16384) until entry.eof?

    entry.rewind

    digester.digest
  end

  ##
  # Extracts the files in this package into +destination_dir+

  def extract_files destination_dir
    verify unless @spec

    FileUtils.mkdir_p destination_dir

    open @gem, 'rb' do |io|
      reader = Gem::Package::TarReader.new io

      reader.each do |entry|
        next unless entry.full_name == 'data.tar.gz'

        extract_tar_gz entry, destination_dir

        return # ignore further entries
      end
    end
  end

  ##
  # Extracts all the files in the gzipped tar archive +io+ into
  # +destination_dir+.
  #
  # If an entry in the archive contains a relative path above
  # +destination_dir+ or an absolute path is encountered an exception is
  # raised.

  def extract_tar_gz io, destination_dir # :nodoc:
    open_tar_gz io do |tar|
      tar.each do |entry|
        destination = install_location entry.full_name, destination_dir

        FileUtils.rm_rf destination

        FileUtils.mkdir_p File.dirname destination

        open destination, 'wb', entry.header.mode do |out|
          out.write entry.read
        end

        say destination if Gem.configuration.really_verbose
      end
    end
  end

  ##
  # Returns the full path for installing +filename+.
  #
  # If +filename+ is not inside +destination_dir+ an exception is raised.

  def install_location filename, destination_dir # :nodoc:
    raise Gem::Package::PathError.new(filename, destination_dir) if
      filename.start_with? '/'

    destination = File.join destination_dir, filename
    destination = File.expand_path destination

    raise Gem::Package::PathError.new(destination, destination_dir) unless
      destination.start_with? destination_dir

    destination.untaint
    destination
  end

  ##
  # Loads a Gem::Specification from the TarEntry +entry+

  def load_spec entry # :nodoc:
    case entry.full_name
    when 'metadata' then
      @spec = Gem::Specification.from_yaml entry.read
    when 'metadata.gz' then
      Zlib::GzipReader.wrap entry do |gzio|
        @spec = Gem::Specification.from_yaml gzio.read
      end
    end
  end

  ##
  # Opens +io+ as a gzipped tar archive

  def open_tar_gz io # :nodoc:
    Zlib::GzipReader.wrap io do |gzio|
      tar = Gem::Package::TarReader.new gzio

      yield tar
    end
  end

  ##
  # The spec for this gem.
  #
  # If this is a package for a built gem the spec is loaded from the
  # gem and returned.  If this is a package for a gem being built the provided
  # spec is returned.

  def spec
    verify unless @spec

    @spec
  end

  ##
  # Verifies that this gem:
  #
  # * Contains a valid gem specification
  # * Contains a contents archive
  # * The contents archive is not corrupt
  #
  # After verification the gem specification from the gem is available from
  # #spec

  def verify
    @files     = []
    @spec      = nil

    digests    = {}
    signatures = {}

    open @gem, 'rb' do |io|
      reader = Gem::Package::TarReader.new io

      reader.each do |entry|
        file_name = entry.full_name
        @files << file_name

        if @security_policy then
          if file_name =~ /.sig$/ then
            signatures[$'] = entry.read
            next
          end

          digests[file_name] = digest entry
        end

        case file_name
        when /^metadata(.gz)?$/ then
          load_spec entry
        when 'data.tar.gz' then
          verify_gz entry
        end
      end
    end

    unless @spec then
      raise Gem::Package::FormatError.new 'package metadata is missing', @gem
    end

    unless @files.include? 'data.tar.gz' then
      raise Gem::Package::FormatError.new \
              'package content (data.tar.gz) is missing', @gem
    end

    verify_signatures digests, signatures

    true
  rescue Errno::ENOENT => e
    raise Gem::Package::FormatError.new e.message
  rescue Gem::Package::TarInvalidError => e
    raise Gem::Package::FormatError.new e.message, @gem
  end

  ##
  # Verifies that +entry+ is a valid gzipped file.

  def verify_gz entry # :nodoc:
    Zlib::GzipReader.wrap entry do |gzio|
      gzio.read 16384 until gzio.eof? # gzip checksum verification
    end
  rescue Zlib::GzipFile::Error => e
    raise Gem::Package::FormatError.new(e.message, entry.full_name)
  end

  ##
  # TODO move to Gem::Security::Policy

  def verify_signatures digests, signatures
    return unless @security_policy

    if @security_policy.only_signed and signatures.empty? then
      raise Gem::Security::Exception,
            "unsigned gems are not allowed by the #{@security_policy} policy"
    end

    digests.each do |file, digest|
      signature = signatures[file]
      raise Gem::Security::Exception, "missing signature for #{file}" unless
        signature
      @security_policy.verify_gem signature, digest, @spec.cert_chain
    end
  end

end

require 'rubygems/package/digest_io'
require 'rubygems/package/old'
require 'rubygems/package/f_sync_dir'
require 'rubygems/package/tar_header'
require 'rubygems/package/tar_reader'
require 'rubygems/package/tar_reader/entry'
require 'rubygems/package/tar_writer'

