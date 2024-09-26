version 1.0

task download_fasta {
  input {
    String         out_prefix
    Array[String]+ accessions
    String         emailAddress

    String         docker = "quay.io/broadinstitute/viral-phylo:2.3.6.0"
  }

  command {
    ncbi.py --version | tee VERSION
    ncbi.py fetch_fastas \
        ${emailAddress} \
        . \
        ${sep=' ' accessions} \
        --combinedFilePrefix ${out_prefix} \
  }

  output {
    File   sequences_fasta  = "${out_prefix}.fasta"
    String viralngs_version = read_string("VERSION")
  }

  runtime {
    docker: docker
    memory: "7 GB"
    cpu: 2
    dx_instance_type: "mem2_ssd1_v2_x2"
    maxRetries: 2
  }
}

task download_annotations {
  input {
    Array[String]+ accessions
    String         emailAddress
    String         combined_out_prefix

    String         docker = "quay.io/broadinstitute/viral-phylo:2.3.6.0"
  }

  command <<<
    set -ex -o pipefail
    ncbi.py --version | tee VERSION
    ncbi.py fetch_feature_tables \
        ~{emailAddress} \
        ./ \
        ~{sep=' ' accessions} \
        --loglevel DEBUG
    mkdir -p combined
    ncbi.py fetch_fastas \
        ~{emailAddress} \
        ./ \
        ~{sep=' ' accessions} \
        --combinedFilePrefix "combined/~{combined_out_prefix}" \
        --forceOverwrite \
        --loglevel DEBUG
  >>>

  output {
    File        combined_fasta   = "combined/~{combined_out_prefix}.fasta"
    Array[File] genomes_fasta    = glob("*.fasta")
    Array[File] features_tbl     = glob("*.tbl")
    String      viralngs_version = read_string("VERSION")
  }

  runtime {
    docker: docker
    memory: "7 GB"
    cpu: 2
    dx_instance_type: "mem2_ssd1_v2_x2"
    maxRetries: 2
  }
}

task sequencing_platform_from_bam {
  input {
    File    bam

    String  docker = "quay.io/broadinstitute/viral-core:2.3.6"
  }

  command <<<
    set -ex -o pipefail
    samtools view -H "~{bam}" | grep '^@RG' | grep -o 'PL:[^[:space:]]*' | cut -d':' -f2 | sort | uniq > BAM_PLATFORMS
    if [ $(wc -l < BAM_PLATFORMS) -ne 1 ]; then
      echo "Other: hybrid" > GENBANK_SEQ_TECH
    elif grep -qi 'ILLUMINA' BAM_PLATFORMS; then
      echo "Illumina" > GENBANK_SEQ_TECH
    elif grep -qi 'ONT' BAM_PLATFORMS; then
      echo "Oxford Nanopore" > GENBANK_SEQ_TECH
    elif grep -qi 'PACBIO' BAM_PLATFORMS; then
      echo "PacBio" > GENBANK_SEQ_TECH
    elif grep -qi 'IONTORRENT' BAM_PLATFORMS; then
      echo "IonTorrent" > GENBANK_SEQ_TECH
    elif grep -qi 'SOLID' BAM_PLATFORMS; then
      echo "SOLiD" > GENBANK_SEQ_TECH
    elif grep -qi 'ULTIMA' BAM_PLATFORMS; then
      echo "Ultima" > GENBANK_SEQ_TECH
    elif grep -qi 'ELEMENT' BAM_PLATFORMS; then
      echo "Element" > GENBANK_SEQ_TECH
    elif grep -qi 'CAPILLARY' BAM_PLATFORMS; then
      echo "Sanger" > GENBANK_SEQ_TECH
    else
      echo "Haven't seen this one before!"
      exit 1
    fi
  >>>

  output {
    String  genbank_sequencing_technology  = read_string("GENBANK_SEQ_TECH")
  }

  runtime {
    docker: docker
    memory: "3 GB"
    cpu: 2
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task annot_transfer {
  meta {
    description: "Given a reference genome annotation in TBL format (e.g. from Genbank or RefSeq) and a multiple alignment of that reference to other genomes, produce new annotation files (TBL format with appropriate coordinate conversions) for each sequence in the multiple alignment. Resulting output can be fed to tbl2asn for Genbank submission."
  }

  input {
    File         multi_aln_fasta
    File         reference_fasta
    Array[File]+ reference_feature_table

    String       docker = "quay.io/broadinstitute/viral-phylo:2.3.6.0"
  }

  parameter_meta {
    multi_aln_fasta: {
      description: "multiple alignment of sample sequences against a reference genome -- for a single chromosome",
      patterns: ["*.fasta"]
    }
    reference_fasta: {
      description: "Reference genome, all segments/chromosomes in one fasta file. Headers must be Genbank accessions.",
      patterns: ["*.fasta"]
    }
    reference_feature_table: {
      description: "NCBI Genbank feature tables, one file for each segment/chromosome described in reference_fasta.",
      patterns: ["*.tbl"]
    }
  }

  command {
    set -e
    ncbi.py --version | tee VERSION
    ncbi.py tbl_transfer_prealigned \
        ${multi_aln_fasta} \
        ${reference_fasta} \
        ${sep=' ' reference_feature_table} \
        . \
        --oob_clip \
        --loglevel DEBUG
  }

  output {
    Array[File] transferred_feature_tables = glob("*.tbl")
    String      viralngs_version           = read_string("VERSION")
  }

  runtime {
    docker: docker
    memory: "3 GB"
    cpu: 2
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task align_and_annot_transfer_single {
  meta {
    description: "Given a reference genome annotation in TBL format (e.g. from Genbank or RefSeq) and new genome not in Genbank, produce new annotation files (TBL format with appropriate coordinate conversions) for the new genome. Resulting output can be fed to tbl2asn for Genbank submission."
  }

  input {
    File         genome_fasta
    Array[File]+ reference_fastas
    Array[File]+ reference_feature_tables

    String       docker = "quay.io/broadinstitute/viral-phylo:2.3.6.0"
  }

  parameter_meta {
    genome_fasta: {
      description: "New genome, all segments/chromosomes in one fasta file. Must contain the same number of sequences as reference_fasta",
      patterns: ["*.fasta"]
    }
    reference_fastas: {
      description: "Reference genome, each segment/chromosome in a separate fasta file, in the exact same count and order as the segments/chromosomes described in genome_fasta. Headers must be Genbank accessions.",
      patterns: ["*.fasta"]
    }
    reference_feature_tables: {
      description: "NCBI Genbank feature table, each segment/chromosome in a separate TBL file, in the exact same count and order as the segments/chromosomes described in genome_fasta and reference_fastas. Accession numbers in the TBL files must correspond exactly to those in reference_fasta.",
      patterns: ["*.tbl"]
    }
  }

  command {
    set -e
    ncbi.py --version | tee VERSION
    mkdir -p out
    ncbi.py tbl_transfer_multichr \
        "${genome_fasta}" \
        out \
        --ref_fastas ${sep=' ' reference_fastas} \
        --ref_tbls ${sep=' ' reference_feature_tables} \
        --oob_clip \
        --loglevel DEBUG
  }

  output {
    Array[File]+ genome_per_chr_tbls   = glob("out/*.tbl")
    Array[File]+ genome_per_chr_fastas = glob("out/*.fasta")
    String       viralngs_version      = read_string("VERSION")
  }

  runtime {
    docker: docker
    memory: "15 GB"
    cpu: 4
    dx_instance_type: "mem2_ssd1_v2_x4"
    preemptible: 1
    maxRetries: 2
  }
}

task structured_comments {
  input {
    File   assembly_stats_tsv

    File?  filter_to_ids

    String docker = "quay.io/broadinstitute/viral-core:2.3.6"
  }
  String out_base = basename(assembly_stats_tsv, '.txt')
  command <<<
    set -e

    python3 << CODE
    import util.file

    samples_to_filter_to = set()
    if "~{default='' filter_to_ids}":
        with open("~{default='' filter_to_ids}", 'rt') as inf:
            samples_to_filter_to = set(line.strip() for line in inf)

    out_headers = ('SeqID', 'StructuredCommentPrefix', 'Assembly Method', 'Coverage', 'Sequencing Technology', 'StructuredCommentSuffix')
    with open("~{out_base}.cmt", 'wt') as outf:
        outf.write('\t'.join(out_headers)+'\n')

        for row in util.file.read_tabfile_dict("~{assembly_stats_tsv}"):
            outrow = dict((h, row.get(h, '')) for h in out_headers)

            if samples_to_filter_to:
              if row['SeqID'] not in samples_to_filter_to:
                  continue

            if outrow['Coverage']:
              outrow['Coverage'] = "{}x".format(round(float(outrow['Coverage'])))
            outrow['StructuredCommentPrefix'] = 'Assembly-Data'
            outrow['StructuredCommentSuffix'] = 'Assembly-Data'
            outf.write('\t'.join(outrow[h] for h in out_headers)+'\n')
    CODE
  >>>
  output {
    File   structured_comment_table = "~{out_base}.cmt"
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task prefix_fasta_header {
  input {
    File   genome_fasta
    String prefix
    String out_basename = basename(genome_fasta, ".fasta")
  }
  command <<<
    set -e
    python3 <<CODE
    with open('~{genome_fasta}', 'rt') as inf:
      with open('~{out_basename}.fasta', 'wt') as outf:
        for line in inf:
          if line.startswith('>'):
            line = ">{}{}\n".format('~{prefix}', line.rstrip()[1:])
          outf.write(line)
    CODE
  >>>
  output {
    File renamed_fasta = "~{out_basename}.fasta"
  }
  runtime {
    docker: "python:slim"
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task rename_fasta_header {
  input {
    File   genome_fasta
    String new_name

    String out_basename = basename(genome_fasta, ".fasta")

    String docker = "quay.io/broadinstitute/viral-core:2.3.6"
  }
  command {
    set -e
    file_utils.py rename_fasta_sequences \
      "~{genome_fasta}" "~{out_basename}.fasta" "~{new_name}"
  }
  output {
    File renamed_fasta = "~{out_basename}.fasta"
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task gisaid_meta_prep {
  input {
    File    source_modifier_table
    File    structured_comments
    String  out_name
    String  continent = "North America"
    Boolean strict = true
    String? username
    String  submitting_lab_name
    String? fasta_filename

    String  address_map = '{}'
    String  authors_map = '{}'
  }
  command <<<
    python3 << CODE
    import os.path
    import csv
    import json

    strict = ~{true="True" false="False" strict}

    # institutional mappings
    address_map = json.loads('~{address_map}')
    authors_map = json.loads('~{authors_map}')
    assert "~{submitting_lab_name}" in address_map, f"error: institution '~{submitting_lab_name}' not found in address_map"

    # lookup table files to dicts
    sample_to_cmt = {}
    with open('~{structured_comments}', 'rt') as inf:
      for row in csv.DictReader(inf, delimiter='\t'):
        sample_to_cmt[row['SeqID']] = row

    out_headers = ('submitter', 'fn', 'covv_virus_name', 'covv_type', 'covv_passage', 'covv_collection_date', 'covv_location', 'covv_add_location', 'covv_host', 'covv_add_host_info', 'covv_sampling_strategy', 'covv_gender', 'covv_patient_age', 'covv_patient_status', 'covv_specimen', 'covv_outbreak', 'covv_last_vaccinated', 'covv_treatment', 'covv_seq_technology', 'covv_assembly_method', 'covv_coverage', 'covv_orig_lab', 'covv_orig_lab_addr', 'covv_provider_sample_id', 'covv_subm_lab', 'covv_subm_lab_addr', 'covv_subm_sample_id', 'covv_authors', 'covv_comment', 'comment_type')

    with open('~{out_name}', 'w', newline='') as outf:
      writer = csv.DictWriter(outf, out_headers, dialect=csv.unix_dialect, quoting=csv.QUOTE_MINIMAL)
      writer.writeheader()

      with open('~{source_modifier_table}', 'rt') as inf:
        for row in csv.DictReader(inf, delimiter='\t'):

          isolation_source = row['isolation_source'].lower()
          #covv_specimen
          if strict:
            valid_isolation_sources = ('clinical', 'environmental')
            assert isolation_source in valid_isolation_sources, f"Metadata error: 'isolation_source' not one of: {valid_isolation_sources}\n{row}"
            assert row['host'] == 'Homo sapiens' or isolation_source == 'environmental', f"Metadata error: 'host' must be 'Homo sapiens' if 'isolation_source' is not 'Environmental'\n{row}"
            assert row['organism']         == 'Severe acute respiratory syndrome coronavirus 2', f"'organism' != 'Severe acute respiratory syndrome coronavirus 2'\n{row}"
            assert row['db_xref']          == 'taxon:2697049', f"Metadata error: 'db_xref' != 'taxon:2697049'\n{row}"

            collected_by = row['collected_by']
            assert collected_by in address_map, f"error: institution '{collected_by}' not found in address_map"
            assert collected_by in authors_map, f"error: institution '{collected_by}' not found in authors_map"

          # PHA4GE/INSDC controlled vocabulary for source information
          # from "Vocabulary" tab of this sheet:
          #   https://github.com/pha4ge/SARS-CoV-2-Contextual-Data-Specification/blob/master/PHA4GE%20SARS-CoV-2%20Contextual%20Data%20Template.xlsx
          gisaid_specimen_source = "unknown"
          if isolation_source == 'clinical':
            gisaid_specimen_source = row.get("body_product",row.get("anatomical_material",row.get("anatomical_part","missing")))
          if isolation_source == 'environmental':
            gisaid_specimen_source = row.get("environmental_material",row.get("environmental_site","missing"))

          writer.writerow({
            'covv_virus_name'     : 'hCoV-19/' +row['Sequence_ID'],
            'covv_collection_date': row['collection_date'],
            'covv_location'       : '~{continent} / ' + row['country'].replace(':',' /'),

            'covv_type'           : 'betacoronavirus',
            'covv_passage'        : 'Original',
            'covv_host'           : 'Human' if isolation_source == 'clinical' else isolation_source.replace("environmental","Environment"),
            'covv_add_host_info'  : 'unknown',
            'covv_gender'         : 'unknown',
            'covv_patient_age'    : 'unknown',
            'covv_patient_status' : 'unknown',
            'covv_specimen'       : gisaid_specimen_source.capitalize(), # capitalization of the first word seems to be the norm for GISAID

            'covv_assembly_method': sample_to_cmt[row['Sequence_ID']]['Assembly Method'],
            'covv_coverage'       : sample_to_cmt[row['Sequence_ID']]['Coverage'],
            'covv_seq_technology' : sample_to_cmt[row['Sequence_ID']]['Sequencing Technology'],

            'covv_orig_lab'       : row['collected_by'],
            'covv_subm_lab'       : "~{submitting_lab_name}",
            'covv_authors'        : authors_map.get(row['collected_by'], 'REQUIRED'),
            'covv_orig_lab_addr'  : address_map.get(row['collected_by'], 'REQUIRED'),
            'covv_subm_lab_addr'  : address_map.get("~{submitting_lab_name}", 'REQUIRED'),

            'submitter'           : "~{default='REQUIRED' username}",
            'fn'                  : "~{default='REQUIRED' fasta_filename}",

            'covv_sampling_strategy'  : row.get('note',''),
          })

    CODE
  >>>
  output {
    File meta_csv = "~{out_name}"
  }
  runtime {
    docker: "python:slim"
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task lookup_table_by_filename {
  input {
    String id
    File   mapping_tsv
    Int    return_col = 2

    String docker = "ubuntu"
  }
  command {
    set -e -o pipefail
    grep ^"~{id}" ~{mapping_tsv} | cut -f ~{return_col} > OUTVAL
  }
  output {
    String value = read_string("OUTVAL")
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task sra_meta_prep {
  meta {
    description: "Prepare tables for submission to NCBI's SRA database. This only works on bam files produced by illumina.py illumina_demux --append_run_id in viral-core."
  }
  input {
    Array[File] cleaned_bam_filepaths
    File        biosample_map
    Array[File] library_metadata
    String      platform
    String      instrument_model
    String      title
    Boolean     paired

    String      out_name = "sra_metadata.tsv"
    String      docker="quay.io/broadinstitute/viral-core:2.3.6"
  }
  Int disk_size = 100
  parameter_meta {
    cleaned_bam_filepaths: {
      description: "Unaligned bam files containing cleaned (submittable) reads.",
      localization_optional: true,
      stream: true,
      patterns: ["*.bam"]
    }
    biosample_map: {
      description: "Tab text file with a header and at least two columns named accession and sample_name. 'accession' maps to the BioSample accession number. Any samples without an accession will be omitted from output. 'sample_name' maps to the internal lab sample name used in filenames, samplesheets, and library_metadata files.",
      patterns: ["*.txt", "*.tsv"]
    }
    library_metadata: {
      description: "Tab text file with a header and at least six columns (sample, library_id_per_sample, library_strategy, library_source, library_selection, design_description). See 3rd tab of https://www.ncbi.nlm.nih.gov/core/assets/sra/files/SRA_metadata_acc_example.xlsx for controlled vocabulary and term definition.",
      patterns: ["*.txt", "*.tsv"]
    }
    platform: {
      description: "Sequencing platform (one of _LS454, ABI_SOLID, BGISEQ, CAPILLARY, COMPLETE_GENOMICS, HELICOS, ILLUMINA, ION_TORRENT, OXFORD_NANOPORE, PACBIO_SMRT)."
    }
    instrument_model: {
      description: "Sequencing instrument model (examples for platform=ILLUMINA: HiSeq X Five, HiSeq X Ten, Illumina Genome Analyzer, Illumina Genome Analyzer II, Illumina Genome Analyzer IIx, Illumina HiScanSQ, Illumina HiSeq 1000, Illumina HiSeq 1500, Illumina HiSeq 2000, Illumina HiSeq 2500, Illumina HiSeq 3000, Illumina HiSeq 4000, Illumina iSeq 100, Illumina NovaSeq 6000, Illumina MiniSeq, Illumina MiSeq, NextSeq 500, NextSeq 550)."
    }
    title: {
      description: "Descriptive sentence of the form <method> of <organism>, e.g. Metagenomic RNA-seq of SARS-CoV-2."
    }
  }
  command <<<
    python3 << CODE
    import os.path
    import csv
    import util.file

    # WDL arrays to python arrays
    bam_uris = list(x for x in '~{sep="*" cleaned_bam_filepaths}'.split('*') if x)
    library_metadata = list(x for x in '~{sep="*" library_metadata}'.split('*') if x)

    # lookup table files to dicts
    lib_to_bams = {}
    sample_to_biosample = {}
    for bam in bam_uris:
      # filename must be <libraryname>.<flowcell>.<lane>.cleaned.bam or <libraryname>.<flowcell>.<lane>.bam
      bam_base = os.path.basename(bam)
      bam_parts = bam_base.split('.')
      assert bam_parts[-1] == 'bam', "filename does not end in .bam -- {}".format(bam) 
      bam_parts = bam_parts[:-1]
      if bam_parts[-1] == 'cleaned':
        bam_parts = bam_parts[:-1]
      assert len(bam_parts) >= 3, "filename does not conform to <libraryname>.<flowcell>.<lane>.cleaned.bam -- {}".format(bam_base)
      lib = '.'.join(bam_parts[:-2]) # drop flowcell and lane
      lib_to_bams.setdefault(lib, [])
      lib_to_bams[lib].append(bam_base)
      print("debug: registering lib={} bam={}".format(lib, bam_base))
    with open('~{biosample_map}', 'rt') as inf:
      for row in csv.DictReader(inf, delimiter='\t'):
        sample_to_biosample[row['sample_name']] = row['accession']

    # set up SRA metadata table
    outrows = []
    out_headers = ['biosample_accession', 'library_ID', 'title', 'library_strategy', 'library_source', 'library_selection', 'library_layout', 'platform', 'instrument_model', 'design_description', 'filetype', 'assembly', 'filename']

    # iterate through library_metadata entries and produce an output row for each entry
    libs_written = set()
    for libfile in library_metadata:
      with open(libfile, 'rt') as inf:
        for row in csv.DictReader(inf, delimiter='\t'):
          lib = util.file.string_to_file_name("{}.l{}".format(row['sample'], row['library_id_per_sample']))
          biosample = sample_to_biosample.get(row['sample'],'')
          bams = lib_to_bams.get(lib,[])
          print("debug: sample={} lib={} biosample={}, bams={}".format(row['sample'], lib, biosample, bams))
          if biosample and bams and lib not in libs_written:
            libs_written.add(lib)
            outrows.append({
              'biosample_accession': sample_to_biosample[row['sample']],
              'library_ID': lib,
              'title': "~{title}",
              'library_strategy': row.get('library_strategy',''),
              'library_source': row.get('library_source',''),
              'library_selection': row.get('library_selection',''),
              'library_layout': '~{true="paired" false="single" paired}',
              'platform': '~{platform}',
              'instrument_model': '~{instrument_model}',
              'design_description': row.get('design_description',''),
              'filetype': 'bam',
              'assembly': 'unaligned',
              'files': lib_to_bams[lib],
            })
    assert outrows, "failed to prepare any metadata -- output is empty!"

    # find library with the most files and add col headers
    n_cols = max(len(row['files']) for row in outrows)
    for i in range(n_cols-1):
      out_headers.append('filename{}'.format(i+2))

    # write output file
    with open('~{out_name}', 'wt') as outf:
      outf.write('\t'.join(out_headers)+'\n')
      for row in outrows:
        row['filename'] = row['files'][0]
        for i in range(len(row['files'])):
          row['filename{}'.format(i+1)] = row['files'][i]
        outf.write('\t'.join(row.get(h,'') for h in out_headers)+'\n')
    CODE
  >>>
  output {
    File sra_metadata     = "~{out_name}"
    File cleaned_bam_uris = write_lines(cleaned_bam_filepaths)
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    disks:  "local-disk " + disk_size + " HDD"
    disk: disk_size + " GB" # TES
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task biosample_to_table {
  meta {
    description: "Reformats a BioSample registration attributes table (attributes.tsv) for ingest into a Terra table."
  }
  input {
    File        biosample_attributes_tsv
    Array[File] cleaned_bam_filepaths
    File        demux_meta_json

    String  sample_table_name  = "sample"
    String  docker = "python:slim"
  }
  String  sanitized_id_col = "entity:~{sample_table_name}_id"
  String base = basename(basename(biosample_attributes_tsv, ".txt"), ".tsv")
  parameter_meta {
    cleaned_bam_filepaths: {
      description: "Unaligned bam files containing cleaned (submittable) reads.",
      localization_optional: true,
      stream: true,
      patterns: ["*.bam"]
    }
  }
  command <<<
    set -ex -o pipefail
    python3 << CODE
    import os.path
    import csv
    import json

    # load demux metadata
    with open("~{demux_meta_json}", 'rt') as inf:
      demux_meta_by_file = json.load(inf)

    # load list of bams surviving filters
    bam_fnames = list(os.path.basename(x) for x in '~{sep="*" cleaned_bam_filepaths}'.split('*'))
    bam_fnames = list(x[:-len('.bam')] if x.endswith('.bam') else x for x in bam_fnames)
    bam_fnames = list(x[:-len('.cleaned')] if x.endswith('.cleaned') else x for x in bam_fnames)
    print("bam basenames ({}): {}".format(len(bam_fnames), bam_fnames))
    sample_to_sanitized = {demux_meta_by_file.get(x, {}).get('sample_original'): demux_meta_by_file.get(x, {}).get('sample') for x in bam_fnames}
    if None in sample_to_sanitized:
      del sample_to_sanitized[None]
    sample_names_seen = sample_to_sanitized.keys()
    print("samples seen ({}): {}".format(len(sample_names_seen), sorted(sample_names_seen)))

    # load biosample metadata
    biosample_attributes = []
    biosample_headers = ['biosample_accession']
    with open('~{biosample_attributes_tsv}', 'rt') as inf:
      for row in csv.DictReader(inf, delimiter='\t'):
        if row['sample_name'] in sample_names_seen and row['message'] == "Successfully loaded":
          row['biosample_accession'] = row.get('accession')
          biosample_attributes.append(row)
          for k,v in row.items():
            if v.strip().lower() in ('missing', 'na', 'not applicable', 'not collected', ''):
              v = None
            if v and (k not in biosample_headers) and k not in ('message', 'accession'):
              biosample_headers.append(k)
    print("biosample headers ({}): {}".format(len(biosample_headers), biosample_headers))
    print("biosample output rows ({})".format(len(biosample_attributes)))
    samples_seen_without_biosample = set(sample_names_seen) - set(row['sample_name'] for row in biosample_attributes)
    print("samples seen in bams without biosample entries ({}): {}".format(len(samples_seen_without_biosample), sorted(samples_seen_without_biosample)))

    # write reformatted table
    with open('~{base}.entities.tsv', 'w', newline='') as outf:
      writer = csv.DictWriter(outf, delimiter='\t', fieldnames=["~{sanitized_id_col}"]+biosample_headers, dialect=csv.unix_dialect, quoting=csv.QUOTE_MINIMAL)
      writer.writeheader()
      for row in biosample_attributes:
        outrow = {h: row[h] for h in biosample_headers}
        outrow["~{sanitized_id_col}"] = sample_to_sanitized[row['sample_name']]
        writer.writerow(outrow)
    CODE
  >>>
  output {
    File sample_meta_tsv = "~{base}.entities.tsv"
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task biosample_to_genbank {
  meta {
    description: "Prepares two input metadata files for Genbank submission based on a BioSample registration attributes table (attributes.tsv) since all of the necessary values are there. This produces both a Genbank Source Modifier Table and a BioSample ID map file that can be fed into the prepare_genbank task."
  }
  input {
    File    biosample_attributes
    Int     taxid
    Int     num_segments = 1
    String  biosample_col_for_fasta_headers = "sample_name"

    File?   filter_to_ids
    Map[String,String] src_to_attr_map = {}

    String  docker = "python:slim"
  }
  String base = basename(basename(biosample_attributes, ".txt"), ".tsv")
  command <<<
    set -ex -o pipefail
    python3<<CODE
    import csv
    import json
    import re

    header_key_map = {
        'Sequence_ID':'~{biosample_col_for_fasta_headers}',
        'BioProject':'bioproject_accession',
        'BioSample':'accession',
    }
    with open("~{write_json(src_to_attr_map)}", 'rt') as inf:
        more_header_key_map = json.load(inf)
    for k,v in more_header_key_map.items():
        header_key_map[k] = v
    print("header_key_map: {}".format(header_key_map))

    datestring_formats = [
        "YYYY-MM-DDTHH:mm:ss", "YYYY-MM-DD", "YYYY-MM", "DD-MMM-YYYY", "MMM-YYYY", "YYYY"
    ]
    out_headers_total = ['Sequence_ID', 'isolate', 'collection_date', 'geo_loc_name', 'collected_by', 'isolation_source', 'organism', 'host', 'note', 'db_xref', 'BioProject', 'BioSample']
    samples_to_filter_to = set()
    if "~{default='' filter_to_ids}":
        with open("~{filter_to_ids}", 'rt') as inf:
            samples_to_filter_to = set(line.strip() for line in inf)
            print("filtering to samples: {}".format(samples_to_filter_to))

    # read entire tsv -> biosample_attributes, filtered to only the entries we keep
    with open("~{biosample_attributes}", 'rt') as inf_biosample:
      biosample_attributes_reader = csv.DictReader(inf_biosample, delimiter='\t')
      in_headers = biosample_attributes_reader.fieldnames
      biosample_attributes = list(row for row in biosample_attributes_reader
        if row['message'].startswith('Success')
        and (not samples_to_filter_to or row[header_key_map['Sequence_ID']] in samples_to_filter_to))
      print("filtered to {} samples".format(len(biosample_attributes)))

    # handle special submission types: flu, sc2, noro, dengue
    for special in ('Influenza A virus', 'Influenza B virus', 'Influenza C virus',
                    'Severe acute respiratory syndrome coronavirus 2',
                    'Norovirus', 'Dengue virus'):
        if any(row['organism'] == special for row in biosample_attributes):
          assert all(row['organism'] == special for row in biosample_attributes), "if any samples are {}, all samples must be {}".format(special, special)
          if 'serotype' not in out_headers_total:
            out_headers_total.append('serotype')
          ### Influenza-specific requirements
          if special.startswith('Influenza'):
            # simplify isolate name
            header_key_map['isolate'] = 'strain'
            for row in biosample_attributes:
              # populate serotype from name parsing
              match = re.search(r'\(([^()]+)\)+$', row['sample_name'])
              if match:
                  row['serotype'] = match.group(1)
              # populate host field from name parsing if empty, override milk
              if 'host' not in row:
                match = re.search(r'[^/]+/([^/]+)/[^/]+/[^/]+/[^/]+', row['sample_name'])
                if match:
                    row['host'] = match.group(1)
                    if row['host'] == 'bovine_milk':
                      row['host'] = 'Cattle'
              # override geo_loc_name if food_origin exists
              if row.get('food_origin','').strip():
                  print("overriding geo_loc_name '{}' with food_origin '{}'".format(row['geo_loc_name'], row['food_origin']))
                  row['geo_loc_name'] = row['food_origin']

    with open("~{base}.genbank.src", 'wt') as outf_smt:
      out_headers = list(h for h in out_headers_total if header_key_map.get(h,h) in in_headers)
      if 'db_xref' not in out_headers:
          out_headers.append('db_xref')
      if 'note' not in out_headers:
          out_headers.append('note')
      if 'serotype' not in out_headers:
          out_headers.append('serotype')
      outf_smt.write('\t'.join(out_headers)+'\n')

      with open("~{base}.sample_ids.txt", 'wt') as outf_ids:
        with open("~{base}.biosample.map.txt", 'wt') as outf_biosample:
          outf_biosample.write('BioSample\tsample\n')

          for row in biosample_attributes:
            # Influenza-specific requirement
            if row['organism'].startswith('Influenza'):
                match = re.search(r'\(([^()]+)\)+$', row[header_key_map.get('isolate','isolate')])
                if match:
                    row['serotype'] = match.group(1)

            # write BioSample
            outf_biosample.write("{}\t{}\n".format(row['accession'], row[header_key_map['Sequence_ID']]))

            # populate output row as a dict
            outrow = dict((h, row.get(header_key_map.get(h,h), '')) for h in out_headers)

            # isolate name should not start with organism string
            if outrow['isolate'].startswith(outrow['organism']):
                outrow['isolate'] = outrow['isolate'][len(outrow['organism']):].strip()

            # some fields are not allowed to be empty
            if not outrow.get('geo_loc_name'):
                outrow['geo_loc_name'] = 'missing'
            if not outrow.get('host'):
                outrow['host'] = 'not applicable'

            # custom db_xref/taxon
            outrow['db_xref'] = "taxon:{}".format(~{taxid})

            # load the purpose of sequencing (or if not, the purpose of sampling) in the note field
            outrow['note'] = row.get('purpose_of_sequencing', row.get('purpose_of_sampling', ''))

            # write entry for this sample
            sample_name = outrow['Sequence_ID']
            if ~{num_segments}>1:
                for i in range(~{num_segments}):
                    outrow['Sequence_ID'] = "{}-{}".format(sample_name, i+1)
                    outf_smt.write('\t'.join(outrow[h] for h in out_headers)+'\n')
                    outf_ids.write(outrow['Sequence_ID']+'\n')
            else:
                outf_smt.write('\t'.join(outrow[h] for h in out_headers)+'\n')
                outf_ids.write(outrow['Sequence_ID']+'\n')
    CODE
  >>>
  output {
    File genbank_source_modifier_table = "~{base}.genbank.src"
    File biosample_map                 = "~{base}.biosample.map.txt"
    File sample_ids                    = "~{base}.sample_ids.txt"
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task generate_author_sbt_file {
  meta {
    description: "Generate an NCBI-compatible author sbt file for submission of sequence data to GenBank. Accepts an author string, a defaults yaml file, and a jinja2-format template. Output is comparable to what is generated by http://www.ncbi.nlm.nih.gov/WebSub/template.cgi"
  }

  input {
    String? author_list
    File    j2_template
    File?   defaults_yaml
    String? out_base = "authors"

    String  docker = "quay.io/broadinstitute/py3-bio:0.1.2"
  }

  parameter_meta {
    author_list: {
      description: "A string containing a space-delimited list with of author surnames separated by first name and (optional) middle initial. Ex. 'Lastname,Firstname, Last-hypenated,First,M., Last,F.'"
    }
    j2_template: {
      description: "an sbt file (optionally) with Jinja2 variables to be filled in based on values present in author_sbt_defaults_yaml, if provided. If no yaml is provided, this file is passed through verbatim. Example: gs://pathogen-public-dbs/other-related/author_template.sbt.j2"
    }
    defaults_yaml: {
      description: "A YAML file with default values to use for the submitter, submitter affiliation, and author affiliation. Optionally including authors at the start and end of the author_list. Example: gs://pathogen-public-dbs/other-related/default_sbt_values.yaml",
      patterns: ["*.yaml","*.yml"]
    }
    out_base: {
      description: "prefix to use for the generated *.sbt output file"
    }
  }
  
  command <<<
    set -e

    # blank yaml file to be used if the optional input is not specified
    touch blank.yml

    python3 << CODE
    # generates an sbt file of the format returned by:
    # http://www.ncbi.nlm.nih.gov/WebSub/template.cgi
    import re
    import shutil
    # external dependencies
    import yaml # pyyaml
    from jinja2 import Template #jinja2

    def render_sbt(author_string, defaults_yaml=None, sbt_out_path="authors.sbt", j2_template="author_template.sbt.j2"):
        # simple version for only initials: #author_re=re.compile(r"\s?(?P<lastname>[\w\'\-\ ]+),(?P<initials>(?:[A-Z]\.){1,3})")
        author_re=re.compile(r"\s?(?P<lastname>[\w\'\-\ ]+),((?P<first>\w[\w\'\-\ ]+\.?),?|(?P<initials>(?:[A-Z]\.)+))(?P<initials_ext>(?:[A-Z]\.)*)")

        authors=[]
        defaults_data_last_authors=[]
        defaults_data = {}

        authors_affil = None
        submitter     = None
        bioproject    = None
        title         = None
        citation      = None

        if defaults_yaml is not None:
            with open(defaults_yaml) as defaults_yaml:
                defaults_data = yaml.load(defaults_yaml, Loader=yaml.FullLoader)

                if defaults_data is not None:
                    submitter     = defaults_data.get("submitter")
                    bioproject    = defaults_data.get("bioproject")
                    title         = defaults_data.get("title")
                    citation      = defaults_data.get("citation")
                    authors_affil = defaults_data.get("authors_affil")
                    
                    defaults_data_authors = defaults_data.get("authors_start",[])
                    for author in defaults_data_authors:
                        authors.extend(author)

                    defaults_data_last_authors = defaults_data.get("authors_last",[])
                    for author in defaults_data_last_authors:
                        last_authors.append(author)
        
        for author_match in author_re.finditer(author_string):
            author = {}
            lastname=author_match.group("lastname")
            initials=[]
            if author_match.group("initials"):
                initials.extend(list(filter(None,author_match.group("initials").split("."))))
            if author_match.group("initials_ext"):
                initials.extend(list(filter(None,author_match.group("initials_ext").split("."))))

            first=""
            if author_match.group("first"):
                first=author_match.group("first")
            else:
                first=initials[0]+"."
            author["last"]     = author_match.group("lastname")
            author["first"]    = first
            author["initials"]   = ".".join(initials[1:]) if not author_match.group("first") else ".".join(initials)
            author["initials"]   = author["initials"]+"." if len(author["initials"])>0 else author["initials"]
            
            if author not in authors: # could use less exact match
                authors.append(author)

        for author in defaults_data_last_authors:
            if author not in authors:
                authors.append(author)

        jinja_rendering_kwargs={}
        if authors_affil is not None:
            jinja_rendering_kwargs["authors_affil"]=authors_affil
        if title is not None:
            jinja_rendering_kwargs["title"]=title
        if submitter is not None:
            jinja_rendering_kwargs["submitter"]=submitter
        if citation is not None:
            jinja_rendering_kwargs["citation"]=citation
        if bioproject is not None:
            jinja_rendering_kwargs["bioproject"]=bioproject

        if len(authors) >= 1 or len(jinja_rendering_kwargs) >= 1:
            with open(j2_template) as sbt_template:
                template = Template(sbt_template.read())

            rendered = template.render( authors=authors, 
                                        **jinja_rendering_kwargs)
        
            #print(rendered)
            with open(sbt_out_path,"w") as sbt_out:
                sbt_out.write(rendered)
        else:
            # if no authors were specified, simply copy the template to the output
            shutil.copyfile(j2_template, sbt_out_path)

    render_sbt("~{author_list}", defaults_yaml="~{default='blank.yml' defaults_yaml}", sbt_out_path="~{out_base}.sbt", j2_template="~{j2_template}")
    CODE
  >>>
  output {
    File sbt_file = "~{out_base}.sbt"
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task prepare_genbank {
  meta {
    description: "this task runs NCBI's tbl2asn"
  }

  input {
    Array[File]+ assemblies_fasta
    Array[File]  annotations_tbl
    File         authors_sbt
    File?        biosampleMap
    File?        genbankSourceTable
    File?        coverage_table
    String?      sequencingTech
    String?      comment
    String?      organism
    String?      molType
    String?      assembly_method
    String?      assembly_method_version

    Int?         machine_mem_gb
    String       docker = "quay.io/broadinstitute/viral-phylo:2.3.6.0"
  }

  parameter_meta {
    assemblies_fasta: {
      description: "Assembled genomes. One chromosome/segment per fasta file.",
      patterns: ["*.fasta"]
    }
    annotations_tbl: {
      description: "Gene annotations in TBL format, one per fasta file. Filename basenames must match the assemblies_fasta basenames. These files are typically output from the ncbi.annot_transfer task.",
      patterns: ["*.tbl"]
    }
    authors_sbt: {
      description: "A genbank submission template file (SBT) with the author list, created at https://submit.ncbi.nlm.nih.gov/genbank/template/submission/",
      patterns: ["*.sbt"]
    }
    biosampleMap: {
      description: "A two column tab text file mapping sample IDs (first column) to NCBI BioSample accession numbers (second column). These typically take the format 'SAMN****' and are obtained by registering your samples first at https://submit.ncbi.nlm.nih.gov/",
      patterns: ["*.txt", "*.tsv"]
    }
    genbankSourceTable: {
      description: "A tab-delimited text file containing requisite metadata for Genbank (a 'source modifier table'). https://www.ncbi.nlm.nih.gov/WebSub/html/help/genbank-source-table.html",
      patterns: ["*.txt", "*.tsv"]
    }
    coverage_table: {
      description: "A two column tab text file mapping sample IDs (first column) to average sequencing coverage (second column, floating point number).",
      patterns: ["*.txt", "*.tsv"]
    }
    sequencingTech: {
      description: "The type of sequencer used to generate reads. NCBI has a controlled vocabulary for this value which can be found here: https://submit.ncbi.nlm.nih.gov/structcomment/nongenomes/"
    }
    organism: {
      description: "The scientific name for the organism being submitted. This is typically the species name and should match the name given by the NCBI Taxonomy database. For more info, see: https://www.ncbi.nlm.nih.gov/Sequin/sequin.hlp.html#Organism"
    }
    molType: {
      description: "The type of molecule being described. Any value allowed by the INSDC controlled vocabulary may be used here. Valid values are described at http://www.insdc.org/controlled-vocabulary-moltype-qualifier"
    }
    assembly_method: {
      description: "Very short description of the software approach used to assemble the genome. We typically provide a github link here. If this is specified, assembly_method_version should also be specified."
    }
    assembly_method_version: {
      description: "The version of the software used. If this is specified, assembly_method should also be specified."
    }
    comment: {
      description: "Optional comments that can be displayed in the COMMENT section of the Genbank record. This may include any disclaimers about assembly quality or notes about pre-publication availability or requests to discuss pre-publication use with authors."
    }

  }

  command {
    set -ex -o pipefail
    ncbi.py --version | tee VERSION
    cp ${sep=' ' annotations_tbl} .

    touch special_args
    if [ -n "${comment}" ]; then
      echo "--comment" >> special_args
      echo "${comment}" >> special_args
    fi
    if [ -n "${sequencingTech}" ]; then
      echo "--sequencing_tech" >> special_args
      echo "${sequencingTech}" >> special_args
    fi
    if [ -n "${organism}" ]; then
      echo "--organism" >> special_args
      echo "${organism}" >> special_args
    fi
    if [ -n "${molType}" ]; then
      echo "--mol_type" >> special_args
      echo "${molType}" >> special_args
    fi
    if [ -n "${assembly_method}" -a -n "${assembly_method_version}" ]; then
      echo "--assembly_method" >> special_args
      echo "${assembly_method}" >> special_args
      echo "--assembly_method_version" >> special_args
      echo "${assembly_method_version}" >> special_args
    fi
    if [ -n "${coverage_table}" ]; then
      echo -e "sample\taln2self_cov_median" > coverage_table.txt
      cat ${coverage_table} >> coverage_table.txt
      echo "--coverage_table" >> special_args
      echo coverage_table.txt >> special_args
    fi

    cat special_args | xargs -d '\n' ncbi.py prep_genbank_files \
        ${authors_sbt} \
        ${sep=' ' assemblies_fasta} \
        . \
        ${'--biosample_map ' + biosampleMap} \
        ${'--master_source_table ' + genbankSourceTable} \
        --loglevel DEBUG
    zip sequins_only.zip *.sqn
    zip all_files.zip *.sqn *.cmt *.gbf *.src *.fsa *.val
    mv errorsummary.val errorsummary.val.txt # to keep it separate from the glob
  }

  output {
    File        submission_zip           = "sequins_only.zip"
    File        archive_zip              = "all_files.zip"
    Array[File] sequin_files             = glob("*.sqn")
    Array[File] structured_comment_files = glob("*.cmt")
    Array[File] genbank_preview_files    = glob("*.gbf")
    Array[File] source_table_files       = glob("*.src")
    Array[File] fasta_per_chr_files      = glob("*.fsa")
    Array[File] validation_files         = glob("*.val")
    File        errorSummary             = "errorsummary.val.txt"
    String      viralngs_version         = read_string("VERSION")
  }

  runtime {
    docker: "${docker}"
    memory: select_first([machine_mem_gb, 3]) + " GB"
    cpu: 2
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task prepare_genbank_single {
  meta {
    description: "this task runs NCBI's tbl2asn"
  }

  input {
    Array[File]+ assemblies_fasta
    Array[File]  annotations_tbl
    File         authors_sbt
    File?        biosampleMap
    File?        genbankSourceTable
    File?        coverage_table
    String?      sequencingTech
    String?      comment
    String?      organism
    String?      molType
    String?      assembly_method
    String?      assembly_method_version

    Int?         machine_mem_gb
    String       docker = "quay.io/broadinstitute/viral-phylo:2.3.6.0"
  }

  parameter_meta {
    assemblies_fasta: {
      description: "Assembled genomes. One chromosome/segment per fasta file.",
      patterns: ["*.fasta"]
    }
    annotations_tbl: {
      description: "Gene annotations in TBL format, one per fasta file. Filename basenames must match the assemblies_fasta basenames. These files are typically output from the ncbi.annot_transfer task.",
      patterns: ["*.tbl"]
    }
    authors_sbt: {
      description: "A genbank submission template file (SBT) with the author list, created at https://submit.ncbi.nlm.nih.gov/genbank/template/submission/",
      patterns: ["*.sbt"]
    }
    biosampleMap: {
      description: "A two column tab text file mapping sample IDs (first column) to NCBI BioSample accession numbers (second column). These typically take the format 'SAMN****' and are obtained by registering your samples first at https://submit.ncbi.nlm.nih.gov/",
      patterns: ["*.txt", "*.tsv"]
    }
    genbankSourceTable: {
      description: "A tab-delimited text file containing requisite metadata for Genbank (a 'source modifier table'). https://www.ncbi.nlm.nih.gov/WebSub/html/help/genbank-source-table.html",
      patterns: ["*.txt", "*.tsv"]
    }
    coverage_table: {
      description: "A two column tab text file mapping sample IDs (first column) to average sequencing coverage (second column, floating point number).",
      patterns: ["*.txt", "*.tsv"]
    }
    sequencingTech: {
      description: "The type of sequencer used to generate reads. NCBI has a controlled vocabulary for this value which can be found here: https://submit.ncbi.nlm.nih.gov/structcomment/nongenomes/"
    }
    organism: {
      description: "The scientific name for the organism being submitted. This is typically the species name and should match the name given by the NCBI Taxonomy database. For more info, see: https://www.ncbi.nlm.nih.gov/Sequin/sequin.hlp.html#Organism"
    }
    molType: {
      description: "The type of molecule being described. Any value allowed by the INSDC controlled vocabulary may be used here. Valid values are described at http://www.insdc.org/controlled-vocabulary-moltype-qualifier"
    }
    assembly_method: {
      description: "Very short description of the software approach used to assemble the genome. We typically provide a github link here. If this is specified, assembly_method_version should also be specified."
    }
    assembly_method_version: {
      description: "The version of the software used. If this is specified, assembly_method should also be specified."
    }
    comment: {
      description: "Optional comments that can be displayed in the COMMENT section of the Genbank record. This may include any disclaimers about assembly quality or notes about pre-publication availability or requests to discuss pre-publication use with authors."
    }

  }

  command {
    set -ex -o pipefail
    ncbi.py --version | tee VERSION
    cp ${sep=' ' annotations_tbl} .

    touch special_args
    if [ -n "${comment}" ]; then
      echo "--comment" >> special_args
      echo "${comment}" >> special_args
    fi
    if [ -n "${sequencingTech}" ]; then
      echo "--sequencing_tech" >> special_args
      echo "${sequencingTech}" >> special_args
    fi
    if [ -n "${organism}" ]; then
      echo "--organism" >> special_args
      echo "${organism}" >> special_args
    fi
    if [ -n "${molType}" ]; then
      echo "--mol_type" >> special_args
      echo "${molType}" >> special_args
    fi
    if [ -n "${assembly_method}" -a -n "${assembly_method_version}" ]; then
      echo "--assembly_method" >> special_args
      echo "${assembly_method}" >> special_args
      echo "--assembly_method_version" >> special_args
      echo "${assembly_method_version}" >> special_args
    fi
    if [ -n "${coverage_table}" ]; then
      echo -e "sample\taln2self_cov_median" > coverage_table.txt
      cat ${coverage_table} >> coverage_table.txt
      echo "--coverage_table" >> special_args
      echo coverage_table.txt >> special_args
    fi

    cat special_args | xargs -d '\n' ncbi.py prep_genbank_files \
        ${authors_sbt} \
        ${sep=' ' assemblies_fasta} \
        . \
        ${'--biosample_map ' + biosampleMap} \
        ${'--master_source_table ' + genbankSourceTable} \
        --loglevel DEBUG
    zip sequins_only.zip *.sqn
    zip all_files.zip *.sqn *.cmt *.gbf *.src *.fsa *.val
    mv errorsummary.val errorsummary.val.txt # to keep it separate from the glob
  }

  output {
    File        submission_zip           = "sequins_only.zip"
    File        archive_zip              = "all_files.zip"
    Array[File] sequin_files             = glob("*.sqn")
    Array[File] structured_comment_files = glob("*.cmt")
    Array[File] genbank_preview_files    = glob("*.gbf")
    Array[File] source_table_files       = glob("*.src")
    Array[File] fasta_per_chr_files      = glob("*.fsa")
    Array[File] validation_files         = glob("*.val")
    File        errorSummary             = "errorsummary.val.txt"
    String      viralngs_version         = read_string("VERSION")
  }

  runtime {
    docker: "${docker}"
    memory: select_first([machine_mem_gb, 3]) + " GB"
    cpu: 2
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task package_sc2_genbank_ftp_submission {
  meta {
    description: "Prepares a zip and xml file for FTP-based NCBI Genbank submission according to instructions at https://www.ncbi.nlm.nih.gov/viewvc/v1/trunk/submit/public-docs/genbank/SARS-CoV-2/."
  }
  input {
    File   sequences_fasta
    File   structured_comment_table
    File   source_modifier_table
    File   author_template_sbt
    String submission_name
    String submission_uid
    String spuid_namespace
    String account_name

    String  docker = "quay.io/broadinstitute/viral-baseimage:0.2.0"
  }
  command <<<
    set -e

    # make the submission zip file
    cp "~{sequences_fasta}" sequence.fsa
    cp "~{structured_comment_table}" comment.cmt
    cp "~{source_modifier_table}" source.src
    cp "~{author_template_sbt}" template.sbt
    zip "~{submission_uid}.zip" sequence.fsa comment.cmt source.src template.sbt

    # make the submission xml file
    SUB_NAME="~{submission_name}"
    ACCT_NAME="~{account_name}"
    SPUID="~{submission_uid}"
    cat << EOF > submission.xml
    <?xml version="1.0"?>
    <Submission>
      <Description>
        <Comment>$SUB_NAME</Comment>
        <Organization type="center" role="owner">
          <Name>$ACCT_NAME</Name>
        </Organization>
      </Description>
      <Action>
        <AddFiles target_db="GenBank">
          <File file_path="$SPUID.zip">
            <DataType>genbank-submission-package</DataType>
          </File>
          <Attribute name="wizard">BankIt_SARSCoV2_api</Attribute>
          <Identifier>
            <SPUID spuid_namespace="~{spuid_namespace}">$SPUID</SPUID>
          </Identifier>
        </AddFiles>
      </Action>
    </Submission>
    EOF

    # make the (empty) ready file
    touch submit.ready
  >>>
  output {
    File submission_zip = "~{submission_uid}.zip"
    File submission_xml = "submission.xml"
    File submit_ready   = "submit.ready"
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task vadr {
  meta {
    description: "Runs NCBI's Viral Annotation DefineR for annotation and QC. Defaults here are for SARS-CoV-2 (see https://github.com/ncbi/vadr/wiki/Coronavirus-annotation), but VADR itself is applicable to a larger number of viral taxa (change the vadr_opts accordingly)."
  }
  input {
    File   genome_fasta
    String vadr_opts = "--glsearch -s -r --nomisc --mkey sarscov2 --lowsim5seq 6 --lowsim3seq 6 --alt_fail lowscore,insertnn,deletinn"

    String docker = "quay.io/staphb/vadr:1.6.3"
    Int    minlen = 50
    Int    maxlen = 30000
    Int    mem_size = 4
    Int    cpus = 2
  }
  String out_base = basename(genome_fasta, '.fasta')
  command <<<
    set -e

    # remove terminal ambiguous nucleotides
    /opt/vadr/vadr/miniscripts/fasta-trim-terminal-ambigs.pl \
      "~{genome_fasta}" \
      --minlen ~{minlen} \
      --maxlen ~{maxlen} \
      > "~{out_base}.fasta"

    # run VADR
    v-annotate.pl \
      ~{vadr_opts} \
      --mdir /opt/vadr/vadr-models/ \
      "~{out_base}.fasta" \
      "~{out_base}"

    # package everything for output
    tar -C "~{out_base}" -czvf "~{out_base}.vadr.tar.gz" .

    # prep alerts into a tsv file for parsing
    cat "~{out_base}/~{out_base}.vadr.alt.list" | cut -f 5 | tail -n +2 \
      > "~{out_base}.vadr.alerts.tsv"
    cat "~{out_base}.vadr.alerts.tsv" | wc -l > NUM_ALERTS
  >>>
  output {
    File                 feature_tbl = "~{out_base}/~{out_base}.vadr.pass.tbl"
    Int                  num_alerts  = read_int("NUM_ALERTS")
    File                 alerts_list = "~{out_base}/~{out_base}.vadr.alt.list"
    Array[Array[String]] alerts      = read_tsv("~{out_base}.vadr.alerts.tsv")
    File                 outputs_tgz = "~{out_base}.vadr.tar.gz"
    Boolean              pass        = num_alerts==0
    String               vadr_docker = docker
  }
  runtime {
    docker: docker
    memory: mem_size + " GB"
    cpu: cpus
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}

task sequence_rename_by_species {
  meta {
    description: "Rename sequences based on species-specific naming conventions for many viral taxa."
  }
  input {
    String sample_id
    String organism_name
    File   biosample_attributes
    String taxid
    File   taxdump_tgz

    String docker = "quay.io/broadinstitute/viral-classify:2.2.4.2"
  }
  command <<<
    set -e
    mkdir -p taxdump
    read_utils.py extract_tarball "~{taxdump_tgz}" taxdump
    python3 << CODE
    import metagenomics
    taxdb = metagenomics.TaxonomyDb(tax_dir='taxdump', load_nodes=True, load_gis=False)
    taxid = int('~{taxid}')
    ancestors = taxdb.get_ordered_ancestors(taxid)


    if any(node == 3052310 for node in [taxid] + ancestors):
      # LASV
      pass
    elif any(node == 186538 for node in [taxid] + ancestors):
      # ZEBOV
      pass
    elif any(node == 11250 for node in [taxid] + ancestors):
      # RSV -- no real convention! Some coalescence around this:
      # <type>/<host lowercase>/Country/ST-Institution-LabID/Year
      # e.g. RSV-A/human/USA/MA-Broad-1234/2020
      pass
    elif any(node == 2697049 for node in [taxid] + ancestors):
      # SARS-CoV-2
      # SARS-CoV-2/<host lowercase>/Country/ST-Institution-LabID/Year
      # e.g. SARS-CoV-2/human/USA/MA-Broad-1234/2020
      pass
    elif any((node == 11320 or node == 11520) for node in [taxid] + ancestors):
      # Flu A or B
      # <type>/<hostname if not human>/<geoloc>/seqUID/year
      # e.g. A/Massachusetts/Broad_MGH-1234/2001 or A/chicken/Hokkaido/TU25-3/2022 or B/Rhode Island/RISHL-1234/2024
      pass
    elif any(node == 12059 for node in [taxid] + ancestors):
      # Enterovirus (including rhinos)
      pass
    else:
      # everything else
      pass

    CODE
  >>>
  output {
    String assembly_name_genbank = read_string("assembly_name_genbank")
  }
  runtime {
    docker: docker
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
    maxRetries: 2
  }
}
