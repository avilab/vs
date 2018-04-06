
def get_fastq(wildcards):
 return config["datadir"] + samples.loc[wildcards.sample, ["fq1", "fq2"]].dropna()

## Run cd-hit to find and munge duplicate reads [5]
rule cd_hit:
  input:
    os.path.join(config["outdir"], "fasta/{sample}.stitched.merged.fasta")
  output:
    clusters = os.path.join(config["outdir"], "cdhit/{sample}.stitched.merged.cdhit.fa"),
    report = os.path.join(config["outdir"], "cdhit/{sample}.stitched.merged.cdhit.report")
  resources:
    mem = 20480
  params:
    "-c 0.984 -G 0 -n 8 -d 0 -aS 0.984 -g 1 -r 1"
  threads:
    40
  shell:
    """
    cd-hit-est -i {input} -o {output.clusters} {params} -T {threads} -M {resources.mem} {params} > {output.report}
    """

## Convert fastq to fasta format [4]
rule fastq2fasta:
  input: os.path.join(config["outdir"], "merged/{sample}.stitched.merged.fq.gz")
  output: os.path.join(config["outdir"], "fasta/{sample}.stitched.merged.fasta")
  shell:
    """
    zcat {input} | sed -n '1~4s/^@/>/p;2~4p' > {output}
    """


## Merge stitched reads
rule merge_reads:
  input:
    join = os.path.join(config["outdir"], "stitched/{sample}.join.fq.gz"),
    un1 = os.path.join(config["outdir"], "stitched/{sample}.un1.fq.gz"),
    un2 = os.path.join(config["outdir"], "stitched/{sample}.un2.fq.gz")
  output:
    merged = os.path.join(config["outdir"], "merged/{sample}.stitched.merged.fq.gz")
  shell:
    """
    cat {input.join} {input.un1} {input.un2} > {output.merged}
    """

## Stitch paired reads [2]
rule fastq_join:
  input:
    pair1 = os.path.join(config["outdir"], "fastp/{sample}.pair1.truncated.gz"),
    pair2 = os.path.join(config["outdir"], "fastp/{sample}.pair2.truncated.gz")
  output:
    os.path.join(config["outdir"], "stitched/{sample}.join.fq.gz"),
    os.path.join(config["outdir"], "stitched/{sample}.un1.fq.gz"),
    os.path.join(config["outdir"], "stitched/{sample}.un2.fq.gz")
  params:
    maximum_difference = 5,
    minimum_overlap = 10,
    template = os.path.join(config["outdir"], "stitched/{sample}.%.fq.gz")
  shell:
    """
    fastq-join \
    -p {params.maximum_difference} \
    -m {params.minimum_overlap} \
    {input.pair1} \
    {input.pair2} \
    -o {params.template}
    """

## All-in-one preprocessing for FastQ files [1,3]
# Adapter trimming is enabled by default
# Quality filtering is enabled by default
# Replaces AdapteRemoval, prinseq and fastqc
rule fastp:
    input:
        get_fastq
    output:
        pair1 = os.path.join(config["outdir"], "fastp/{sample}.pair1.truncated.gz"),
        pair2 = os.path.join(config["outdir"], "fastp/{sample}.pair2.truncated.gz")
    params:
        options = "-f 5 -t 5 -l 50 -y -Y 8",
        html = os.path.join(config["outdir"], "fastp/{sample}.report.html"),
        json = os.path.join(config["outdir"], "fastp/{sample}.report.json")
    threads: 16
    shell:
        """
        fastp -i {input[0]} -I {input[1]} -o {output.pair1} -O {output.pair2} {params.options} -h {params.html} -j {params.json} -w {threads}
        """
