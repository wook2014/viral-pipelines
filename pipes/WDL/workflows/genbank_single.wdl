version 1.0

import "../tasks/tasks_ncbi.wdl" as ncbi
import "../tasks/tasks_ncbi_tools.wdl" as ncbi_tools
import "../tasks/tasks_reports.wdl" as reports
import "../tasks/tasks_utils.wdl" as utils

workflow genbank_single {

    meta {
        description: "Prepare assemblies for Genbank submission. This includes annotation by simple coordinate transfer from Genbank annotations and a multiple alignment. See https://viral-pipelines.readthedocs.io/en/latest/ncbi_submission.html for details."
        author: "Broad Viral Genomics"
        email:  "viral-ngs@broadinstitute.org"
        allowNestedInputs: true
    }

    input {
        File          assembly_fasta
        String        ref_accessions_colon_delim

        File          aligned_reads_bam
        String        biosample_accession
        Int           tax_id

        String        email_address # required for fetching data from NCBI APIs
        File?         biosample_attributes_tsv # if empty, we will fetch from NCBI via accession
    }

    parameter_meta {
        assembly_fasta: {
          description: "Genome to prepare for Genbank submission. All segments/chromosomes included in one file. Must contain exactly the same number of sequences as reference_accessions.",
          patterns: ["*.fasta"]
        }
        ref_accessions_colon_delim: {
          description: "Reference genome Genbank accessions, each segment/chromosome in the exact same count and order as the segments/chromosomes described in assemblies_fasta. List of accessions should be colon delimited.",
          patterns: ["*.fasta"]
        }
        biosample_attributes_tsv: {
          description: "A post-submission attributes file from NCBI BioSample, which is available at https://submit.ncbi.nlm.nih.gov/subs/ and clicking on 'Download attributes file with BioSample accessions'.",
          patterns: ["*.txt", "*.tsv"]
        }
    }

    # fetch biosample metadata from NCBI if it's not given to us in tsv form
    if(!defined(biosample_attributes_tsv)) {
        call ncbi_tools.fetch_biosamples {
            input:
                biosample_ids = [biosample_accession],
                out_basename = "biosample_attributes-~{biosample_accession}"
        }
    }
    File biosample_attributes = select_first([biosample_attributes_tsv, fetch_biosamples.biosample_attributes_tsv])

    # extract info from aligned bams (coverage, seq tech)
    call ncbi.sequencing_platform_from_bam {
      input:
        bam = aligned_reads_bam
    }
    call reports.coverage_report {
      input:
        mapped_bams = [aligned_reads_bam],
        out_report_name = "coverage_report-~{basename(aligned_reads_bam, '.bam')}.txt"
    }

    # Is this a special virus that NCBI handles differently?
    call ncbi.genbank_special_taxa {
      input:
        taxid = tax_id
    }

    # Annotate genes
    ## fetch reference genome sequences and annoations
    call utils.string_split {
        input:
            joined_string = ref_accessions_colon_delim,
            delimiter = ":"
    }
    scatter(segment_acc in string_split.tokens) {
      ## scatter these calls in order to preserve original order
      call ncbi.download_annotations {
        input:
          accessions = [segment_acc],
          emailAddress = email_address,
          combined_out_prefix = segment_acc
      }
    }
    # create genbank source modifier table from biosample metadata
    call ncbi.biosample_to_genbank {
        input:
            biosample_attributes = biosample_attributes,
            num_segments         = length(string_split.tokens),
            taxid                = tax_id
    }
    ## naive liftover of gene coordinates by alignment
    call ncbi.align_and_annot_transfer_single as annot {
        input:
            genome_fasta             = assembly_fasta,
            reference_fastas         = flatten(download_annotations.genomes_fasta),
            reference_feature_tables = flatten(download_annotations.features_tbl)
    }
    if(genbank_special_taxa.vadr_supported) {
      call ncbi.vadr {
        input:
          genome_fasta    = assembly_fasta,
          maxlen          = genbank_special_taxa.max_genome_length,
          vadr_opts       = genbank_special_taxa.vadr_cli_options,
          vadr_model_tar  = genbank_special_taxa.vadr_model_tar,
      }
    }
    File feature_tbl   = select_first([vadr.feature_tbl, annot.feature_tbl])

    call ncbi.structured_comments_from_coverage_report {
      input:
            coverage_report         = coverage_report.coverage_report,
            assembly_fasta          = assembly_fasta,
            sequencing_tech         = sequencing_platform_from_bam.genbank_sequencing_technology
    }

    if(genbank_special_taxa.table2asn_allowed) {
      call ncbi.table2asn {
        input:
            assembly_fasta          = assembly_fasta,
            annotations_tbl         = feature_tbl,
            source_modifier_table   = biosample_to_genbank.genbank_source_modifier_table,
            structured_comment_file = structured_comments_from_coverage_report.structured_comment_file
      }
    }

    output {
        File?       genbank_submission_sqn = table2asn.genbank_submission_sqn
        File?       genbank_preview_file   = table2asn.genbank_preview_file
        File?       table2asn_errors       = table2asn.genbank_validation_file
        File        genbank_comment_file   = structured_comments_from_coverage_report.structured_comment_file
        Boolean?    vadr_pass              = vadr.pass

        File        genbank_source_table   = biosample_to_genbank.genbank_source_modifier_table
        File        annotation_tbl         = feature_tbl
    }

}
