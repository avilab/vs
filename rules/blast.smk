
# Helper function to import tables
def safely_read_csv(path, **kwargs):
  try:
    return pd.read_csv(path, **kwargs)
  except pd.errors.EmptyDataError:
    pass

def concatenate_tables(input, output, sep = "\s+"):
  frames = [safely_read_csv(f, sep = sep) for f in input]
  pd.concat(frames, keys = input).to_csv(output[0], index = False)

def filter_taxons(input, viruses, non_viral, sep = ","):
  tab = safely_read_csv(f, sep = sep)
  vir = tab[tab.superkingdom == 10239]
  non_vir = tab[tab.superkingdom != 10239]
  vir.to_csv(viruses[0], index = False)
  non_vir.to_csv(non_viral[0], index = False)

rule get_virus_taxids:
    output: "blast/10239.taxids"
    params:
       taxid = 10239
    conda:
        "https://raw.githubusercontent.com/avilab/virome-wrappers/master/blast/query/environment.yaml"
    shell:
       "get_species_taxids.sh -t {params.taxid} > {output}"

# Blastn, megablast and blastx input, output, and params keys must match commandline blast option names. Please see https://www.ncbi.nlm.nih.gov/books/NBK279684/#appendices.Options_for_the_commandline_a for all available options.
# Blast against nt virus database.
rule blastn_virus:
    input:
      query = rules.parse_megablast_refgenome.output.unmapped,
       taxidlist = "blast/10239.taxids"
    output:
      out = temp("blast/{run}_blastn-virus_{n}.tsv")
    params:
      program = "blastn",
      db = "nt_v5",
      evalue = 1e-4,
      max_hsps = 50,
      outfmt = "'6 qseqid sacc staxid pident length evalue'"
    threads: 2
    wrapper:
      "https://raw.githubusercontent.com/avilab/virome-wrappers/blast5/blast/query"

# Filter blastn hits for the cutoff value.
rule parse_blastn_virus:
    input:
      query = rules.parse_megablast_refgenome.output.unmapped,
      blast_result = rules.blastn_virus.output.out
    output:
      mapped = temp("blast/{run}_blastn-virus_{n}_mapped.tsv"),
      unmapped = temp("blast/{run}_blastn-virus_{n}_unmapped.fa")
    params:
      e_cutoff = 1e-5,
      outfmt = rules.blastn_virus.params.outfmt
    wrapper:
      "https://raw.githubusercontent.com/avilab/virome-wrappers/master/blast/parse"

# Blastx unmapped reads against nr virus database.
rule blastx_virus:
    input:
      query = rules.parse_blastn_virus.output.unmapped,
      taxidlist = "blast/10239.taxids"
    output:
      out = temp("blast/{run}_blastx-virus_{n}.tsv")
    params:
      program = "blastx",
      task = "Blastx-fast",
      db = "nr_v5",
      evalue = 1e-2,
      db_soft_mask = 100,
      max_hsps = 50,
      outfmt = rules.blastn_virus.params.outfmt
    threads: 2
    wrapper:
      "https://raw.githubusercontent.com/avilab/virome-wrappers/blast5/blast/query"

# Filter blastn hits for the cutoff value.
rule parse_blastx_virus:
    input:
      query = rules.blastx_virus.input.query,
      blast_result = rules.blastx_virus.output.out
    output:
      mapped = temp("blast/{run}_blastx-virus_{n}_mapped.tsv"),
      unmapped = temp("blast/{run}_blastx-virus_{n}_unmapped.fa")
    params:
      e_cutoff = 1e-3,
      outfmt = rules.megablast_refgenome.params.outfmt
    wrapper:
      "https://raw.githubusercontent.com/avilab/virome-wrappers/master/blast/parse"

# Filter sequences by division id.
# Saves hits with division id
rule classify_viruses:
  input:
    [rules.parse_blastn_virus.output.mapped, rules.parse_blastx_virus.output.mapped] if config["run_blastx"] else rules.parse_blastn_virus.output.mapped
  output:
    temp("results/{run}_viruses_{n}.csv")
  wrapper:
    "https://raw.githubusercontent.com/avilab/virome-wrappers/blast5/blast/taxonomy"

# Merge virus blast results
rule merge_classify_viruses_results:
  input:
    expand("results/{{run}}_viruses_{n}.csv", n = N)
  output:
    "results/{run}_viruses.csv"
  run:
    concatenate_tables(input, output, sep = ",")

# Filter unmasked candidate virus reads.
rule unmasked_other:
    input:
      rules.parse_blastx_virus.output.unmapped if config["run_blastx"] else rules.parse_blastn_virus.output.unmapped,
      rules.repeatmasker_good.output.original_filt
    output:
      temp("blast/{run}_candidate-viruses_{n}_unmasked.fa")
    wrapper:
      "https://raw.githubusercontent.com/avilab/virome-wrappers/blast5/subset_fasta"

# Map reads to bacterial genomes.
rule bwa_mem_refbac:
    input:
      reads = [rules.unmasked_other.output]
    output:
      temp("blast/{run}_bac-mapped_{n}.bam")
    params:
      index = REF_BACTERIA,
      extra = "-k 15",
      sort = "none"
    log:
      "logs/{run}_bwa-map-refbac_{n}.log"
    threads: 2
    wrapper:
      "0.32.0/bio/bwa/mem"

# Extract unmapped reads and convert to fasta.
rule unmapped_refbac:
  input:
    rules.bwa_mem_refbac.output
  output:
    fastq = temp("blast/{run}_unmapped_{n}.fq"),
    fasta = temp("blast/{run}_unmapped_{n}.fa")
  wrapper:
    "https://raw.githubusercontent.com/avilab/virome-wrappers/master/unmapped"

# Calculate bam file stats
rule refbac_bam_stats:
    input:
      rules.bwa_mem_refbac.output
    output:
      "stats/{run}_refbac-stats_{n}.txt"
    params:
      extra = "-f 4",
      region = ""
    wrapper:
        "0.32.0/bio/samtools/stats"

# Subset repeatmasker masked reads using unmapped reads.
rule refbac_unmapped_masked:
    input:
      rules.unmapped_refbac.output.fasta,
      rules.repeatmasker_good.output.masked_filt
    output:
      temp("blast/{run}_unmapped_{n}_masked.fa")
    wrapper:
      "https://raw.githubusercontent.com/avilab/virome-wrappers/blast5/subset_fasta"

# Megablast against nt database.
rule megablast_nt:
    input:
      query = rules.refbac_unmapped_masked.output
    output:
      out = temp("blast/{run}_megablast-nt_{n}.tsv")
    params:
      program = "blastn",
      db = "nt_v5",
      task = "megablast",
      evalue = 1e-8,
      word_size = 16,
      max_hsps = 50,
      outfmt = rules.blastn_virus.params.outfmt
    threads: 2
    wrapper:
      BLAST

# Filter megablast hits for the cutoff value.
rule parse_megablast_nt:
    input:
      query = rules.refbac_unmapped_masked.output,
      blast_result = rules.megablast_nt.output.out
    output:
      mapped = temp("blast/{run}_megablast-nt_{n}_mapped.tsv"),
      unmapped = temp("blast/{run}_megablast-nt_{n}_unmapped.fa")
    params:
      e_cutoff = 1e-10,
      outfmt = rules.blastn_virus.params.outfmt
    wrapper:
      PARSE_BLAST

# Blastn against nt database.
rule blastn_nt:
    input:
      query = rules.parse_megablast_nt.output.unmapped
    output:
      out = temp("blast/{run}_blastn-nt_{n}.tsv")
    params:
      program = "blastn",
      db = "nt_v5",
      task = "blastn",
      evalue = 1e-8,
      max_hsps = 50,
      outfmt = rules.blastn_virus.params.outfmt
    threads: 2
    wrapper:
      BLAST

# Filter blastn records for the cutoff value.
rule parse_blastn_nt:
    input:
      query = rules.blastn_nt.input.query,
      blast_result = rules.blastn_nt.output.out
    output:
      mapped = temp("blast/{run}_blastn-nt_{n}_mapped.tsv"),
      unmapped = temp("blast/{run}_blastn-nt_{n}_unmapped.fa")
    params:
      e_cutoff = 1e-10,
      outfmt = rules.blastn_virus.params.outfmt
    wrapper:
      PARSE_BLAST

# Blastx unmapped sequences against nr database.
rule blastx_nr:
    input:
      query = rules.parse_blastn_nt.output.unmapped
    output:
      out = temp("blast/{run}_blastx-nr_{n}.tsv")
    params:
      program = "blastx",
      task = "Blastx-fast",
      db = "nr_v5",
      evalue = 1e-2,
      max_hsps = 50,
      outfmt = rules.blastn_virus.params.outfmt
    threads: 2
    wrapper:
      BLAST

# Filter blastx records for the cutoff value.
rule parse_blastx_nr:
    input:
      query = rules.blastx_nr.input.query,
      blast_result = rules.blastx_nr.output.out
    output:
      mapped = temp("blast/{run}_blastx-nr_{n}_mapped.tsv"),
      unmapped = temp("blast/{run}_blastx-nr_{n}_unmapped.fa")
    params:
      e_cutoff = 1e-3,
      outfmt = rules.blastn_virus.params.outfmt
    wrapper:
      PARSE_BLAST

# Filter sequences by division id.
# Saves hits with division id
rule classify:
  input:
    expand("blast/{{run}}_{blastresult}_{{n}}_mapped.tsv", blastresult = BLASTNR)
  output:
    temp("results/{run}_classified_{n}.csv")
  wrapper:
    "https://raw.githubusercontent.com/avilab/virome-wrappers/blast5/blast/taxonomy"

rule filter_viruses:
  input:
    rules.classify.output
  output:
    viral = "results/{run}_phages-viruses_{n}.csv",
    non_viral = "results/{run}_non-viral_{n}.csv"
  run:
    filter_viruses(input, output.viral, output.non_viral, sep = ",")

# Merge virus blast results
rule merge_viruses:
  input:
    expand("results/{{run}}_phages-viruses_{n}.csv", n = N)
  output:
    "results/{run}_phages-viruses.csv"
  run:
    concatenate_tables(input, output, sep = ",")

# Merge blast results for classification
rule merge_non_viral:
  input:
    expand("results/{{run}}_non-viral_{n}.csv", n = N)
  output:
    "results/{run}_non-viral.csv"
  run:
    concatenate_tables(input, output, sep = ",")

# Merge unassigned sequences
rule merge_unassigned:
  input:
    expand("blast/{{run}}_blast{type}_{n}_unmapped.fa", type = "x-nr" if config["run_blastx"] else "n-nt", n = N)
  output:
    "results/{run}_unassigned.fa"
  shell:
    "cat {input} > {output}"

# Collect stats.
rule blast_stats:
  input:
    expand(["blast/{{run}}_{blastresult}_{n}_unmapped.fa",
    "blast/{{run}}_candidate-viruses_{n}_unmasked.fa",
    "blast/{{run}}_unmapped_{n}.fa",
    "blast/{{run}}_unmapped_{n}_masked.fa"], blastresult = BLAST, n = N)
  output:
    "stats/{run}_blast.tsv"
  params:
    extra = "-T"
  wrapper:
    config["wrappers"]["stats"]

# Upload results to Zenodo.
if config["zenodo"]["deposition_id"]:
  rule upload_results:
    input:
      expand("results/{{run}}_{result}", result = RESULTS)
    output:
      ZEN.remote("results/{run}_counts.tgz")
    shell:
      "tar czvf {output} {input}"

  rule upload_stats:
    input:
      "stats/{run}_refgenome-stats.txt",
      "stats/{run}_preprocess.tsv",
      "stats/{run}_blast.tsv",
      expand("stats/{{run}}_refbac-stats_{n}.txt", n = N)
    output:
      ZEN.remote("stats/{run}_stats.tgz")
    shell:
      "tar czvf {output} {input}"
