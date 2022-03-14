#!/bin/bash

set -x

while getopts ":i:v:o:c:" flag
do
    case "${flag}" in
        i) SAMPLE=${OPTARG};;
        v) VCF=${OPTARG};;
        o) OUTDIR=${OPTARG};;
        c) CPU=${OPTARG};;
        \?) valid=0
            echo "An invalid option has been entered: $OPTARG"
            exit 0
            ;;

        :)  valid=0
            echo "The additional argument for option $OPTARG was omitted."
            exit 0
            ;;

    esac
done

shift "$(( OPTIND - 1 ))"

if [ -z "$SAMPLE" ]; then
        echo 'Missing -i ID' >&2
        exit 1
fi

if [ -z "$VCF" ]; then
        echo 'Missing -v VCF file' >&2
        exit 1
fi

if [ -z "$OUTDIR" ]; then
        echo 'Missing -o output directory' >&2
        exit 1
fi

if [ -z "$CPU" ]; then
      echo 'Missing -c CPU' >&2
      exit 1
fi

echo $SAMPLE
echo $VCF
echo $OUTDIR
echo $CPU


# sample directories
SAMPLEDIR=${OUTDIR}/${SAMPLE}/${SAMPLE}_ANCESTRY_REPORT
SAMPLE_SUP=${OUTDIR}/${SAMPLE}/${SAMPLE}_ANCESTRY_SUPPLEMENTARY
TEMPDIR=${SAMPLE_SUP}/TEMP
LOG=${SAMPLE_SUP}/LOG

mkdir -p ${SAMPLEDIR}
mkdir -p ${SAMPLE_SUP}
mkdir -p ${TEMPDIR}
mkdir -p ${LOG}

# reference files
CONFIG=$PWD/Configuration
REF_HAPMAP3=${CONFIG}/Reference_HapMap3
REF_BED_HAPMAP3=${REF_HAPMAP3}/HapMapIII_CGRCh37.admixture
REF_HAPMAP3_POP=${CONFIG}/HapMap_ID2Pop.txt

{
  plink --vcf ${VCF} \
      --make-bed \
      --const-fid 0 \
      --allow-extra-chr \
      --out ${TEMPDIR}/${SAMPLE}_original

  mv ${TEMPDIR}/${SAMPLE}_original.log ${LOG}/Binary_1.log


  # HapMap3

  ## Make the binary files WITHOUT rsIDs

  plink2 --bfile ${TEMPDIR}/${SAMPLE}_original \
      --make-bed \
      --set-all-var-ids @:\#:\$r:\$a \
      --new-id-max-allele-len 1000 \
      --allow-extra-chr \
      --out ${TEMPDIR}/${SAMPLE}

  mv ${TEMPDIR}/${SAMPLE}.log ${LOG}/Original_2.log

  ## Filter study data for non A-T or G-C SNPs

  awk 'BEGIN {OFS="\t"} ($5$6 == "GC" || $5$6 == "CG" || $5$6 == "AT" || $5$6 == "TA") {print $2}' \
  ${TEMPDIR}/${SAMPLE}.bim > \
  ${TEMPDIR}/${SAMPLE}.ac_gt_snps

  plink --bfile ${TEMPDIR}/${SAMPLE} \
  --exclude ${TEMPDIR}/${SAMPLE}.ac_gt_snps \
  --make-bed \
  --allow-extra-chr \
  --out ${TEMPDIR}/${SAMPLE}.no_ac_gt_snps
  mv ${TEMPDIR}/${SAMPLE}.no_ac_gt_snps.log ${LOG}/no_ac_gt_snps_3.log

  ## Prune Study Data

  plink --bfile ${TEMPDIR}/${SAMPLE}.no_ac_gt_snps \
  --exclude range ${CONFIG}/highld.txt \
  --indep-pairwise 50 5 0.2 \
  --make-bed \
  --allow-extra-chr \
  --out ${TEMPDIR}/${SAMPLE}.no_ac_gt_snps_prune_pass1
  mv ${TEMPDIR}/${SAMPLE}.no_ac_gt_snps_prune_pass1.log ${LOG}/no_ac_gt_snps_prune_pass1_4.log

  plink --bfile ${TEMPDIR}/${SAMPLE}.no_ac_gt_snps \
  --extract ${TEMPDIR}/${SAMPLE}.no_ac_gt_snps_prune_pass1.bim \
  --make-bed \
  --allow-extra-chr \
  --out ${SAMPLE_SUP}/${SAMPLE}.pruned
  mv ${SAMPLE_SUP}/${SAMPLE}.pruned.log ${LOG}/pruned_5.log

  ## Filter reference data for the same SNP set as in study and remove duplicates

  plink2 --bfile ${REF_BED_HAPMAP3} \
  --extract ${SAMPLE_SUP}/${SAMPLE}.pruned.bim \
  --make-bed \
  --allow-extra-chr \
  --rm-dup force-first \
  --out ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.pruned.no_dups
  mv ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.pruned.no_dups.log ${LOG}/ref_HAPMAP3.pruned.no_dups_6.log


  ## Check and correct chromosome mismatch

  awk 'BEGIN {OFS="\t"} FNR==NR {a[$2]=$1; next} ($2 in a && a[$2] != $1) {print a[$2],$2}' \
  ${SAMPLE_SUP}/${SAMPLE}.pruned.bim ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.pruned.no_dups.bim | \
  sed -n '/^[XY]/!p' > ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.toUpdateChr

  plink --bfile ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.pruned.no_dups \
  --update-chr ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.toUpdateChr 1 2 \
  --make-bed \
  --allow-extra-chr \
  --out ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.updateChr
  mv ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.updateChr.log ${LOG}/ref_HAPMAP3.updateChr_7.log

  ## Position Match

  awk 'BEGIN {OFS="\t"} FNR==NR {a[$2]=$4; next} \
  ($2 in a && a[$2] != $4) {print a[$2],$2}' \
  ${SAMPLE_SUP}/${SAMPLE}.pruned.bim ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.pruned.no_dups.bim > \
  ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.toUpdatePos

  ## Possible allele flips

  awk 'BEGIN {OFS="\t"} FNR==NR {a[$1$2$4]=$5$6; next} \
  ($1$2$4 in a && a[$1$2$4] != $5$6 && a[$1$2$4] != $6$5) {print $2}' \
  ${SAMPLE_SUP}/${SAMPLE}.pruned.bim ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.pruned.no_dups.bim > \
  ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.toFlip

  ## Update positions and flip alleles

  plink --bfile ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.updateChr \
  --update-map ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.toUpdatePos 1 2 \
  --flip ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.toFlip \
  --make-bed \
  --allow-extra-chr \
  --out ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.flipped
  mv ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.flipped.log ${LOG}/ref_HAPMAP3.flipped_8.log

  ## Remove mismatches

  awk 'BEGIN {OFS="\t"} FNR==NR {a[$1$2$4]=$5$6; next} \
  ($1$2$4 in a && a[$1$2$4] != $5$6 && a[$1$2$4] != $6$5) {print $2}' \
  ${SAMPLE_SUP}/${SAMPLE}.pruned.bim ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.flipped.bim > \
  ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.flipped.mismatch

  plink --bfile ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.flipped \
  --exclude ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.flipped.mismatch \
  --make-bed \
  --allow-extra-chr \
  --out ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.clean
  mv ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.clean.log  ${LOG}/ref_HAPMAP3.clean_9.log


  ## Merge study genotypes and reference data

  plink --bfile ${SAMPLE_SUP}/${SAMPLE}.pruned \
  --bmerge ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.clean.bed ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.clean.bim \
  ${TEMPDIR}/${SAMPLE}_ref_HAPMAP3.clean.fam \
  --make-bed \
  --allow-extra-chr \
  --out ${TEMPDIR}/${SAMPLE}.merge_ref_HAPMAP3

  mv ${TEMPDIR}/${SAMPLE}.merge_ref_HAPMAP3.log ${LOG}/merge_ref_HAPMAP3_10.log


  ## Prepare for Admixture

  plink --bfile ${TEMPDIR}/${SAMPLE}.merge_ref_HAPMAP3 \
  --geno 0.999 \
  --make-bed \
  --allow-extra-chr \
  --out ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3
  mv ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.log ${LOG}/admixture_ref_HAPMAP3_11.log



  # Admixture

  # NOTE: Admixture always outputs into the current directory

  # Hapmap3
  awk 'FNR==NR{a[$2]=$3;next}{print $0,a[$2]?a[$2]:"-"}' ${REF_HAPMAP3_POP} ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.fam \
    > ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.txt
  awk '{print $7}' ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.txt > ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.pop

  admixture ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.bed 11 --supervised -j${CPU}
  mv ${SAMPLE}.admixture_ref_HAPMAP3.11.Q ${SAMPLE_SUP}
  mv ${SAMPLE}.admixture_ref_HAPMAP3.11.P ${SAMPLE_SUP}

  rm -r ${TEMPDIR}

  # Graphical outputs
  Rscript admixture_pie.R ${SAMPLEDIR} ${SAMPLE}_HapMap3 ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.11.Q \
    ${SAMPLE_SUP}/${SAMPLE}.admixture_ref_HAPMAP3.fam ${REF_HAPMAP3_POP} "HapMap3" ${CONFIG}

} 2>&1 | tee ${LOG}/ancestry.log
