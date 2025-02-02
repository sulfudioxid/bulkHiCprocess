import os
import numpy as np

SAMPLES = [i.replace(".pairs.gz","") for i in os.listdir("processed/pairs/")]
#SAMPLES = ["laneGM"]

###############################################
# call compartment and TAD like Hi-C 3.0
# draw saddle plot and calc comapartment strength
# update on 20211202 by zliu to 

configfile: "bulkHiCprocess/config.yaml"

rule all:
    input:
       # expand("processed/TADs/{sample}.tad.bed",sample=SAMPLES),
        expand("processed/compartment/{sample}.compartment.100k.cis.vecs.tsv",sample=SAMPLES),
        expand("processed/expected/{sample}.100k.expected.tsv",sample=SAMPLES),
        expand("processed/saddle/{sample}.saddle.saddledump.npz",sample=SAMPLES),
        "processed/saddle/compartmentStrength.txt",  

rule pairs2cool:
    input:
        pairs = "processed/pairs/{sample}.pairs.gz",
        chr_len = config["refs"][config["ref_genome"]]["chr_len"],
    output:
        balancedCool = "processed/cools/{sample}.5k.balanced.cool",
    params:
        resolution = 5000,
    threads: 8
    shell:"""
        set +u
        source activate
        conda activate hic2
        set -u

        cooler cload pairs -c1 2 -c2 4 -p1 3 -p2 5 {input.chr_len}:{params.resolution} {input.pairs} {output.balancedCool}
        cooler balance {output.balancedCool}

        set +u
        conda deactivate
        set -u
    """

rule generate_mcool:
    input:
        balancedCool = rules.pairs2cool.output.balancedCool,
    output:
        mcool = "processed/mcools/{sample}.balanced.mcool"
    threads: 10
    shell:"""
    
        set +u
        source activate
        conda activate hic2
        set -u
        
        cooler zoomify -p {threads} {input.balancedCool} -r 5000,20000,50000,100000,200000,500000,1000000 --balance -o {output.mcool} 

        set +u
        conda deactivate
        set -u
    """
    
rule call_compartment:
    input:
        mcool = rules.generate_mcool.output.mcool,
        comaprtment_ref_track = config["refs"][config["ref_genome"]]["compartment_ref_track"],
    output:
        compartment = "processed/compartment/{sample}.compartment.100k.cis.vecs.tsv"
    params:
        resolution=100000
    shell:"""
        set +u
        source activate
        conda activate hic2
        set -u
        mkdir -p processed/compartment
        cooltools eigs-cis {input.mcool}::/resolutions/{params.resolution} --phasing-track {input.comaprtment_ref_track} -o ./processed/compartment/{wildcards.sample}.compartment.100k --bigwig

        set +u
        conda deactivate
        set -u
    """

rule compute_expected:
    input:
        mcool = rules.generate_mcool.output.mcool
    output:
        expected100k = "processed/expected/{sample}.100k.expected.tsv"

    threads: 10
    params:
        resolution=100000
    shell:"""
        set +u
        source activate
        conda activate hic2
        set -u

        cooltools expected-cis {input.mcool}::/resolutions/{params.resolution}  -p {threads} -o {output.expected100k}

        set +u
        conda deactivate
        set -u
    """

rule call_tad:
    input:
        coolpath = rules.pairs2cool.output.balancedCool,
    output:
        insulationScore = "processed/insulation/{sample}.standardTAD.tsv",
    shell:"""
        set +u
        source activate
        conda activate hic2
        set -u
        
        cooltools insulation {input.coolpath} --ignore-diags 2 --window-pixels 20 40 60 80 100 200 > {output.insulationScore}
        
        set +u
        conda deactivate
        set -u
    """

rule compartmentVecs2bed:
    input:
        rawCom = rules.call_compartment.output.compartment,
    output:
        compartmentbed = "processed/compartment/{sample}.compartment.100k.bed",
        tmpfile = temp("processed/compartment/{sample}.temp.bed")
    shell:"""
        set +u
        source activate
        conda activate R
        set -u

        Rscript ./bulkHiCprocess/scripts/compartmentVecs2bed.R {input.rawCom} {output.tmpfile}

        bedtools merge -s -d 3 -i {output.tmpfile} -o distinct -c 5 > {output.compartmentbed}

        set +u
        conda deactivate
        set -u
    """

rule cleanTADs:
    input:
        rawTADs = rules.call_tad.output.insulationScore,
        comp = rules.compartmentVecs2bed.output.compartmentbed,
    output:
        cleanedTADs = "processed/TADs/{sample}.tad.bed"

    shell:"""
        set +u
        source activate
        conda activate R
        set -u

        Rscript ./bulkHiCprocess/scripts/cleanTADs.R {input.comp} {input.rawTADs} {output.cleanedTADs}

        set +u
        conda deactivate
        set -u
    """

rule compute_saddle:
    input:
        expected = rules.compute_expected.output.expected100k,
        mcool = rules.generate_mcool.output.mcool,
        compartment = "processed/compartment/{sample}.compartment.100k.cis.vecs.tsv",
    output:
        saddleplot = "processed/saddle/{sample}.saddle.png",
        saddle_strength = "processed/saddle/{sample}.saddle.saddledump.npz",
    params:
        resolution = 100000
    shell:"""
        set +u
        source activate
        conda activate hic2
        set -u
        cooltools saddle {input.mcool}::/resolutions/{params.resolution} \
        ./processed/compartment/{wildcards.sample}.compartment.100k.cis.vecs.tsv::E1 {input.expected} \
        -o ./processed/saddle/{wildcards.sample}.saddle --fig png --strength --qrange 0.025 0.975
        set +u
        conda deactivate
        set -u
    """

rule compute_strength:
    input:
        expand(rules.compute_saddle.output.saddle_strength,sample = SAMPLES)
    output:
        "processed/saddle/compartmentStrength.txt"
    run:
        with open(output[0],'w') as out:
            for file in input:
                out.write(file)
		out.write("\n")
                out.write(str(np.load(file)['saddle_strength'][10]))
                out.write("\n")
        print("All done!")

