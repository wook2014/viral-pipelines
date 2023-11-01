version 1.0

task gcs_copy {
  input {
    Array[File] infiles
    String      gcs_uri_prefix
  }
  meta {
    description: "gsutil cp. only works on a GCP-based backend (e.g. Terra)"
  }
  parameter_meta {
    infiles: {
      description: "Input files",
      localization_optional: true,
      stream: true
    }
  }
  command {
    set -e
    gsutil -m cp ~{sep=' ' infiles} ~{gcs_uri_prefix}
  }
  output {
    File logs = stdout()
  }
  runtime {
    docker: "quay.io/broadinstitute/viral-baseimage:0.1.20"
    memory: "1 GB"
    cpu: 1
    maxRetries: 1
  }
}

task check_terra_env {
  input {
    String docker = "quay.io/broadinstitute/viral-core:2.2.2" #skip-global-version-pin
  }
  meta {
    description: "task for inspection of backend to determine whether the task is running on Terra and/or GCP"
  }
  command <<<
    set -ex

    # create gcloud-related output file
    touch gcloud_config_info.log
    touch google_project_id.txt

    # create Terra-related output files
    touch workspace_name.txt
    touch workspace_namespace.txt
    touch workspace_bucket_path.txt
    touch input_table_name.txt
    touch input_row_id.txt

    # write system environment variables to output file
    env | tee -a env_info.log

    GOOGLE_PROJECT_ID="$(gcloud config list --format='value(core.project)')"
    echo "$GOOGLE_PROJECT_ID" > google_project_id.txt

    # check whether gcloud project has a "terra-" prefix
    # to determine if running on Terra
    if case ${GOOGLE_PROJECT_ID} in terra-*) ;; *) false;; esac; then
      # (shell-portable regex conditional)
      echo "Job appears to be running on Terra (GCP project ID: ${GOOGLE_PROJECT_ID})"
      echo "true" > RUNNING_ON_TERRA
    else
      echo "NOT running on Terra"
      echo "false" > RUNNING_ON_TERRA
    fi

    # check if running on GCP
    if curl -s metadata.google.internal -i | grep -E 'Metadata-Flavor:\s+Google'; then 
      echo "Cloud platform appears to be GCP"; 
      echo "true" > RUNNING_ON_GCP

      # write gcloud env info to output files
      gcloud info | tee -a gcloud_config_info.log
    else 
      echo "NOT running on GCP";
      echo "false" > RUNNING_ON_GCP
    fi

    if grep "true" RUNNING_ON_GCP && grep "true" RUNNING_ON_TERRA; then 
      echo "Running on Terra+GCP"

      # === Determine Terra workspace name and namespace for the workspace responsible for this job

      # Scrape out various workflow / workspace info from the localization and delocalization scripts.
      #   from: https://github.com/broadinstitute/gatk/blob/ah_var_store/scripts/variantstore/wdl/GvsUtils.wdl#L35-L40
      sed -n -E 's!.*gs://fc-(secure-)?([^\/]+).*!\2!p' /cromwell_root/gcs_delocalization.sh | sort -u 
      sed -n -E 's!.*(gs://(fc-(secure-)?[^\/]+)).*!\1!p' /cromwell_root/gcs_delocalization.sh | sort -u 

      # top-level submission ID
      TOP_LEVEL_SUBMISSION_ID="$(sed -n -E 's!.*gs://fc-(secure-)?([^\/]+)/submissions/([^\/]+).*!\3!p' /cromwell_root/gcs_delocalization.sh | sort -u)"
      echo "TOP_LEVEL_SUBMISSION_ID: ${TOP_LEVEL_SUBMISSION_ID}"
      # workflow job ID within submission
      sed -n -E 's!.*gs://fc-(secure-)?([^\/]+)/submissions/([^\/]+)/([^\/]+)/([^\/]+).*!\5!p' /cromwell_root/gcs_delocalization.sh | sort -u 

      sed -n -E 's!.*(terra-[0-9a-f]+).*# project to use if requester pays$!\1!p' /cromwell_root/gcs_localization.sh | sort -u 

      # MORE DIRECT IF BUCKET PATH IS KNOWN:
      #curl -X 'GET' \
      #  'https://rawls.dsde-prod.broadinstitute.org/api/workspaces/id/8819db8a-7afb-4a27-97e2-6c314968b421?fields=workspace.name%2Cworkspace.namespace' \
      #  -H 'accept: application/json' \
      #  -H "Authorization: Bearer $(gcloud auth print-access-token)"

      # get list of workspaces, limiting the output to only the fields we need
      curl -s -X 'GET' \
      'https://api.firecloud.org/api/workspaces?fields=workspace.name%2Cworkspace.namespace%2Cworkspace.bucketName%2Cworkspace.googleProject' \
      -H 'accept: application/json' \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" > workspace_list.json

      # extract workspace name
      WORKSPACE_NAME=$(jq -cr '.[] | select( .workspace.googleProject == "'${GOOGLE_PROJECT_ID}'" ).workspace | .name' workspace_list.json)
      echo "$WORKSPACE_NAME" | tee workspace_name.txt
      
      # extract workspace namespace
      WORKSPACE_NAMESPACE=$(jq -cr '.[] | select( .workspace.googleProject == "'${GOOGLE_PROJECT_ID}'" ).workspace | .namespace' workspace_list.json)
      WORKSPACE_NAME_URL_ENCODED="$(jq -rn --arg x "${WORKSPACE_NAME}" '$x|@uri')"
      echo "$WORKSPACE_NAMESPACE" | tee workspace_namespace.txt

      # extract workspace bucket
      WORKSPACE_BUCKET=$(jq -cr '.[] | select( .workspace.googleProject == "'${GOOGLE_PROJECT_ID}'" ).workspace | .bucketName' workspace_list.json)
      echo "gs://${WORKSPACE_BUCKET}" | tee workspace_bucket_path.txt

      touch submission_metadata.json
      curl -s -X 'GET' \
      "https://api.firecloud.org/api/workspaces/${WORKSPACE_NAMESPACE}/${WORKSPACE_NAME_URL_ENCODED}/submissions/${TOP_LEVEL_SUBMISSION_ID}" \
      -H 'accept: application/json' \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" > submission_metadata.json

      INPUT_TABLE_NAME="$(jq -cr '.submissionEntity.entityType | select (.!=null)' submission_metadata.json)"
      echo "$INPUT_TABLE_NAME" | tee input_table_name.txt
      INPUT_ROW_ID="$(jq -cr '.submissionEntity.entityName | select (.!=null)' submission_metadata.json)"
      echo "$INPUT_ROW_ID" | tee input_row_id.txt
    else 
      echo "Not running on Terra+GCP"
    fi

  >>>
  output {
    Boolean is_running_on_terra  = read_boolean("RUNNING_ON_TERRA")
    Boolean is_backed_by_gcp     = read_boolean("RUNNING_ON_GCP")

    String workspace_name        = read_string("workspace_name.txt")
    String workspace_namespace   = read_string("workspace_namespace.txt")
    String workspace_bucket_path = read_string("workspace_bucket_path.txt")
    String google_project_id     = read_string("google_project_id.txt")
    String input_table_name      = read_string("input_table_name.txt")
    String input_row_id          = read_string("input_row_id.txt")

    File env_info                = "env_info.log"
    File gcloud_config_info      = "gcloud_config_info.log"
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    maxRetries: 1
  }
}

task upload_reads_assemblies_entities_tsv {
  input {
    String        workspace_name
    String        terra_project
    File          tsv_file
    Array[String] cleaned_reads_unaligned_bams_string
    File          meta_by_filename_json

    String        docker = "schaluvadi/pathogen-genomic-surveillance:api-wdl"
  }
  command {
    set -e

    echo ~{sep="," cleaned_reads_unaligned_bams_string} > cleaned_bam_strings.txt

    python3 /projects/cdc-sabeti-covid-19/create_data_tables.py \
        -t "~{tsv_file}" \
        -p "~{terra_project}" \
        -w "~{workspace_name}" \
        -b cleaned_bam_strings.txt \
        -j "~{meta_by_filename_json}" \
        | perl -lape 's/^.*Check your workspace for new (\S+) table.*/$1/' \
        > TABLES_MODIFIED
  }
  runtime {
    docker: docker
    memory: "2 GB"
    cpu: 1
    maxRetries: 0
  }
  output {
    Array[String] tables = read_lines('TABLES_MODIFIED')
  }
}

task upload_entities_tsv {
  input {
    String        workspace_name
    String        terra_project
    File          tsv_file

    String        docker = "schaluvadi/pathogen-genomic-surveillance:api-wdl"
  }
  command {
    set -e
    python3<<CODE
    import sys
    from firecloud import api as fapi
    response = fapi.upload_entities_tsv(
      '~{terra_project}', '~{workspace_name}', '~{tsv_file}', model="flexible")
    if response.status_code != 200:
        print('ERROR UPLOADING: See full error message:')
        print(response.text)
        sys.exit(1)
    else:
        print("Upload complete. Check your workspace for new table!")
    CODE
  }
  runtime {
    docker: docker
    memory: "2 GB"
    cpu: 1
    maxRetries: 0
  }
  output {
    Array[String] stdout = read_lines(stdout())
  }
}

task download_entities_tsv {
  input {
    String  terra_project
    String  workspace_name
    String  table_name
    String  outname = "~{terra_project}-~{workspace_name}-~{table_name}.tsv"
    String? nop_input_string # this does absolutely nothing, except that it allows an optional mechanism for you to block execution of this step upon the completion of another task in your workflow

    String  docker = "schaluvadi/pathogen-genomic-surveillance:api-wdl"
  }

  meta {
    volatile: true
  }

  command {
    python3<<CODE
    import csv
    import json
    import collections

    from firecloud import api as fapi

    workspace_project = '~{terra_project}'
    workspace_name = '~{workspace_name}'
    table_name = '~{table_name}'
    out_fname = '~{outname}'
    nop_string = '~{default="" nop_input_string}'

    # load terra table and convert to list of dicts
    # I've found that fapi.get_entities_tsv produces malformed outputs if funky chars are in any of the cells of the table
    table = json.loads(fapi.get_entities(workspace_project, workspace_name, table_name).text)
    headers = collections.OrderedDict()
    rows = []
    headers[table_name + "_id"] = 0
    for row in table:
        outrow = row['attributes']
        for x in outrow.keys():
            headers[x] = 0
            if type(outrow[x]) == dict and set(outrow[x].keys()) == set(('itemsType', 'items')):
                outrow[x] = outrow[x]['items']
        outrow[table_name + "_id"] = row['name']
        rows.append(outrow)

    # dump to tsv
    with open(out_fname, 'wt') as outf:
      writer = csv.DictWriter(outf, headers.keys(), delimiter='\t', dialect=csv.unix_dialect, quoting=csv.QUOTE_MINIMAL)
      writer.writeheader()
      writer.writerows(rows)
    CODE
  }
  runtime {
    docker: docker
    memory: "2 GB"
    cpu: 1
    maxRetries: 2
  }
  output {
    File tsv_file = '~{outname}'
  }
}

task create_or_update_sample_tables {
  input {
    String flowcell_run_id

    String workspace_namespace
    String workspace_name
    String workspace_bucket

    String  docker = "quay.io/broadinstitute/viral-core:2.2.2" #skip-global-version-pin
  }

  meta {
    volatile: true
  }

  command <<<
    python3<<CODE

    workspace_project = '~{workspace_namespace}'
    workspace_name    = '~{workspace_name}'
    workspace_bucket  = '~{workspace_bucket}'
    table_name        = ''

    CODE
  >>>
  runtime {
    docker: docker
    memory: "2 GB"
    cpu: 1
    maxRetries: 2
  }
  output {
    File stdout_log = stdout()
    File stderr_log = stderr()
  }
}
