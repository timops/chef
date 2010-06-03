#
# Author:: Tim Hinderliter (<tim@opscode.com>)
# Copyright:: Copyright (c) 2010 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/sandbox'
require 'chef/checksum'

# Sandboxes are used to upload files to the server (e.g., cookbook upload).
class Sandboxes < Application
  
  provides :json

  before :authenticate_every

  include Chef::Mixin::Checksum
  include Merb::TarballHelper
  
  def index
    couch_sandbox_list = Chef::Sandbox::cdb_list(true)
    
    sandbox_list = Hash.new
    couch_sandbox_list.each do |sandbox|
      sandbox_list[sandbox.guid] = absolute_url(:sandbox, :sandbox_id => sandbox.guid)
    end
    display sandbox_list
  end

  def show
    begin
      sandbox = Chef::Sandbox.cdb_load(params[:sandbox_id])
    rescue Chef::Exceptions::CouchDBNotFound => e
      raise NotFound, "Cannot find a sandbox named #{params[:sandbox_id]}"
    end

    display sandbox
  end
 
  def create
    checksums = params[:checksums]
    
    raise BadRequest, "missing required parameter: checksums" unless checksums
    raise BadRequest, "required parameter checksums is not a hash: #{checksums.class.name}" unless checksums.is_a?(Hash)

    new_sandbox = Chef::Sandbox.new
    result_checksums = Hash.new
    
    all_existing_checksums = Chef::Checksum.cdb_all_checksums
    checksums.keys.each do |checksum|
      if all_existing_checksums[checksum]
        result_checksums[checksum] = {
          :needs_upload => false
        }
      else
        result_checksums[checksum] = {
          :url => absolute_url(:sandbox_checksum, :sandbox_id => new_sandbox.guid, :checksum => checksum),
          :needs_upload => true
        }
        new_sandbox.checksums << checksum
      end
    end
    
    FileUtils.mkdir_p(sandbox_location(new_sandbox.guid))
    
    new_sandbox.cdb_save
    
    # construct successful response
    self.status = 201
    location = absolute_url(:sandbox, :sandbox_id => new_sandbox.guid)
    headers['Location'] = location
    result = { 'uri' => location, 'checksums' => result_checksums, 'sandbox_id' => new_sandbox.guid }
    #result = { 'uri' => location }
    
    display result
  end
  
  def upload_checksum
    sandbox_guid = params[:sandbox_id]
    checksum = params[:checksum]
    
    existing_sandbox = Chef::Sandbox.cdb_load(sandbox_guid)
    raise NotFound, "cannot find sandbox with guid #{sandbox_guid}" unless existing_sandbox  
    raise NotFound, "checksum #{checksum} isn't a part of sandbox #{sandbox_guid}" unless existing_sandbox.checksums.member?(checksum)

    Tempfile.open("sandbox") do |src|
      src.write(self.request.env["rack.input"].string) 
      src.close

      observed_checksum = Chef::Cache::Checksum.generate_md5_checksum_for_file(src.path)
      
      raise BadRequest, "Checksum did not match: expected #{checksum}, observed #{observed_checksum}" unless observed_checksum == checksum
    
      dest = sandbox_checksum_location(sandbox_guid, checksum)
      Chef::Log.info("upload_checksum: move #{src} to #{dest}")
      FileUtils.mv(src.path, dest)
    end
    
    url = absolute_url(:sandbox_checksum, :sandbox_id => sandbox_guid, :checksum => checksum)
    result = { 'uri' => url }
    display result
  end
  
  def update
    # look up the sandbox by its guid
    existing_sandbox = Chef::Sandbox.cdb_load(params[:sandbox_id])
    raise NotFound, "cannot find sandbox with guid #{sandbox_id}" unless existing_sandbox
    
    raise BadRequest, "cannot update sandbox #{sandbox_id}: already complete" if existing_sandbox.is_completed

    if params[:is_completed]
      existing_sandbox.is_completed = (params[:is_completed] == true)

      if existing_sandbox.is_completed
        # Check if files were uploaded to sandbox directory before we 
        # commit the sandbox. Fail if any weren't.
        existing_sandbox.checksums.each do |checksum|
          checksum_filename = sandbox_checksum_location(existing_sandbox.guid, checksum)
          if !File.exists?(checksum_filename)
            raise BadRequest, "cannot update sandbox #{params[:sandbox_id]}: checksum #{checksum} was not uploaded"
          end
        end
        
        # If we've gotten here all the files have been uploaded.
        # Track the steps to undo everything we've done. If any steps fail,
        # we will undo the successful steps that came before it
        begin
          undo_steps = Array.new
          existing_sandbox.checksums.each do |checksum|
            checksum_filename_in_sandbox = sandbox_checksum_location(existing_sandbox.guid, checksum)
            checksum_filename_final = checksum_location(checksum)
            FileUtils.mkdir_p File.dirname(checksum_filename_final)
            
            Chef::Log.info("sandbox finalization: move #{checksum_filename_in_sandbox} to #{checksum_filename_final}")
            File.rename(checksum_filename_in_sandbox, checksum_filename_final)
            
            # mark the checksum as successfully updated
            Chef::Checksum.new(checksum).cdb_save
            
            undo_steps << proc {
              Chef::Log.warn("sandbox finalization undo: moving #{checksum_filename_final} back to #{checksum_filename_in_sandbox}")
              File.rename(checksum_filename_final, checksum_filename_in_sandbox)
            }
          end
        rescue
          # undo the successful moves we did before
          Chef::Log.error("sandbox finalization: got exception moving files, undoing previous changes: #{$!} -- #{$!.backtrace.join("\n")}")
          undo_steps.each do |undo_step|
            undo_step.call
          end
          raise
        end
        
      end
    end
    
    existing_sandbox.cdb_save

    display existing_sandbox
  end
  
  def destroy
    raise NotFound, "Destroy not implemented"
  end
  
end
