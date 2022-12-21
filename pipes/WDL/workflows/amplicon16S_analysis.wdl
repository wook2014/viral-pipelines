version 1.0

import "../tasks/tasks_16S_amplicon.wdl" as qiime 

workflow amplicon16S_analysis {
    
    meta {
        description: "Running 16S amplicon (from BAM format) sequencing analysis with qiime."
        author: "fnegrete"
        email:  "viral_ngs@broadinstitute.org"
        allowNestedInputs: true 
    }
    input {
        File    reads_bam
        File    trained_classifier
        String  sample_name
        Boolean keep_untrimmed_reads 
    }

    call qiime.qiime_import_from_bam {
        input:
            reads_bam  = reads_bam,
            sample_name = sample_name
    }
    #__________________________________________
    call qiime.trim_reads {
        input:
           reads_qza            = qiime_import_from_bam.reads_qza,
           keep_untrimmed_reads = keep_untrimmed_reads
    }
    #__________________________________________
    call qiime.join_paired_ends {
        input: 
            trimmed_reads_qza = trim_reads.trimmed_reads_qza
    }
    #_________________________________________
    call qiime.deblur {
        input: 
            joined_end_reads_qza = join_paired_ends.joined_end_reads_qza
    }
    #_________________________________________
    call qiime.tax_analysis {
        input:
            trained_classifier = trained_classifier,
            representative_seqs_qza = deblur.representative_seqs_qza,
            representative_table_qza = deblur.representative_table_qza
    }
}