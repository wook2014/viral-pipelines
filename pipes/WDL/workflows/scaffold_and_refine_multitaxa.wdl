version 1.0

import "../tasks/tasks_assembly.wdl" as assembly
import "../tasks/tasks_metagenomics.wdl" as metagenomics
import "../tasks/tasks_ncbi.wdl" as ncbi
import "../tasks/tasks_utils.wdl" as utils
import "assemble_refbased.wdl" as assemble_refbased

workflow scaffold_and_refine_multitaxa {
    meta {
        description: "Scaffold de novo contigs against a set of possible references and subsequently polish with reads."
        author: "Broad Viral Genomics"
        email:  "viral-ngs@broadinstitute.org"
        allowNestedInputs: true
    }

    input {
        String  sample_id
        File    reads_unmapped_bam

        File    taxid_to_ref_accessions_tsv
        File?   focal_report_tsv
        File?   ncbi_taxdump_tgz

        # Float    min_pct_reference_covered = 0.1
    }

    # if kraken reports are available, filter scaffold list to observed hits (output might be empty!)
    if(defined(focal_report_tsv) && defined(ncbi_taxdump_tgz)) {
        call metagenomics.filter_refs_to_found_taxa {
            input:
                taxid_to_ref_accessions_tsv = taxid_to_ref_accessions_tsv,
                taxdump_tgz = select_first([ncbi_taxdump_tgz]),
                focal_report_tsv = select_first([focal_report_tsv])
        }
    }

    Array[Array[String]] taxid_to_ref_accessions = read_tsv(select_first([filter_refs_to_found_taxa.filtered_taxid_to_ref_accessions_tsv, taxid_to_ref_accessions_tsv]))
    Array[String] assembly_header = ["sample_id", "taxid", "tax_name", "assembly_fasta", "aligned_only_reads_bam", "coverage_plot", "assembly_length", "assembly_length_unambiguous", "reads_aligned", "mean_coverage", "percent_reference_covered", "intermediate_gapfill_fasta", "assembly_preimpute_length_unambiguous", "replicate_concordant_sites", "replicate_discordant_snps", "replicate_discordant_indels", "replicate_discordant_vcf", "isnvsFile", "aligned_bam", "coverage_tsv", "read_pairs_aligned", "bases_aligned"]

    scatter(taxon in taxid_to_ref_accessions) {
        # taxon = [taxid, taxname, semicolon_delim_accession_list]
        if(length(taxon)>1) { # <-- workaround for serious bug in cromwell's read_tsv on empty files
            call utils.string_split {
                input:
                    joined_string = taxon[2],
                    delimiter = ";"
            }
            call ncbi.download_annotations {
                input:
                    accessions = string_split.tokens,
                    combined_out_prefix = taxon[0]
            }
            call assembly.scaffold {
                input:
                    reads_bam = reads_unmapped_bam,
                    reference_genome_fasta = [download_annotations.combined_fasta],
                    min_length_fraction = 0,
                    min_unambig = 0,
                    allow_incomplete_output = true
            }
            call assemble_refbased.assemble_refbased as refine {
                input:
                    reads_unmapped_bams = [reads_unmapped_bam],
                    reference_fasta     = scaffold.scaffold_fasta,
                    sample_name         = sample_id
            }
            # TO DO: if percent_reference_covered > some threshold, run ncbi.rename_fasta_header and ncbi.align_and_annot_transfer_single
            # TO DO: if biosample attributes file provided, run ncbi.biosample_to_genbank

            if (refine.reference_genome_length > 0) {
                Float percent_reference_covered = 1.0 * refine.assembly_length_unambiguous / refine.reference_genome_length
            }

            Map[String, String] stats_by_taxon = {
                "sample_id" : sample_id,
                "taxid" : taxon[0],
                "tax_name" : taxon[1],

                "assembly_fasta" : refine.assembly_fasta,
                "aligned_only_reads_bam" : refine.align_to_self_merged_aligned_only_bam,
                "coverage_plot" : refine.align_to_self_merged_coverage_plot,
                "assembly_length" : refine.assembly_length,
                "assembly_length_unambiguous" : refine.assembly_length_unambiguous,
                "reads_aligned" : refine.align_to_self_merged_reads_aligned,
                "mean_coverage" : refine.align_to_self_merged_mean_coverage,
                "percent_reference_covered" : select_first([percent_reference_covered, 0.0]),

                "intermediate_gapfill_fasta" : scaffold.intermediate_gapfill_fasta,
                "assembly_preimpute_length_unambiguous" : scaffold.assembly_preimpute_length_unambiguous,

                "replicate_concordant_sites" : refine.replicate_concordant_sites,
                "replicate_discordant_snps" : refine.replicate_discordant_snps,
                "replicate_discordant_indels" : refine.replicate_discordant_indels,
                "replicate_discordant_vcf" : refine.replicate_discordant_vcf,

                "isnvsFile" : refine.align_to_self_isnvs_vcf,
                "aligned_bam" : refine.align_to_self_merged_aligned_only_bam,
                "coverage_tsv" : refine.align_to_self_merged_coverage_tsv,
                "read_pairs_aligned" : refine.align_to_self_merged_read_pairs_aligned,
                "bases_aligned" : refine.align_to_self_merged_bases_aligned
            }

            scatter(h in assembly_header) {
                String stat_by_taxon = stats_by_taxon[h]
            }
        }
    }
 
    ### summary stats
    call utils.concatenate {
      input:
        infiles     = [write_tsv([assembly_header]), write_tsv(select_all(stat_by_taxon))],
        output_name = "assembly_metadata-~{sample_id}.tsv"
    }

    output {
        Array[Map[String,String]] assembly_stats_by_taxon  = stats_by_taxon
        File   assembly_stats_by_taxon_tsv                 = concatenate.combined
        String assembly_method                             = "viral-ngs/scaffold_and_refine_multitaxa"

        # TO DO: some summary stats on stats_by_taxon: how many rows, numbers from the best row, etc
    }
}
