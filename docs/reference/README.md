# Reference documents

`pdf/` and `txt/` are not committed (copyrighted). They live on this machine;
this file says where they came from.

- `pdf/` -- copied from the NAS share
  `smb://daninas.local/software/HP9000/HP9000/` (mounted at
  `/run/user/1000/gvfs/smb-share:server=daninas.local,share=software/HP9000/HP9000`),
  with `Pa-arch.zip` unpacked into `pdf/arch/` and `Pa-chips.zip` into `pdf/chips/`.
- `pdf/bitsavers/` -- from bitsavers.org (2026-10-07):
  - `components/ncr_symbios/scsi/53C710/NCR_53C710_53C710-1_SCSI_IO_Processor_Data_Manual_Jun92.pdf`
  - `components/ncr_symbios/scsi/53C700/53C700_SCSI_IO_Processor_Programmers_Guide_Mar90.pdf` (SCRIPTS)
  - `components/crystalSemiconductor/_dataSheets/CS4215.pdf` (Harmony's codec)
  - `pdf/hp/pa-risc/5960-3149_Support_Tools_Manual_PA-RISC_Vol_1_SPU_Vol_2_Device_Adapters_Dec92.pdf`
  - `pdf/hp/pa-risc/OpenPA_PA-RISC_Print_2024.pdf`
  - `pdf/hp/9000_hpux/1991-200x/199304_B2355-9V155/9V255_HP-UX_Starbase_Device_Drivers_Manual_Volume_1/2_Series_700.pdf`
- `txt/` -- `pdftotext -layout` of every PDF (same base name), for grep:

  ```bash
  cd docs/reference/pdf && for f in *.pdf arch/*.pdf chips/*.pdf bitsavers/*.pdf; do
    pdftotext -layout "$f" "../txt/$(basename "${f%.pdf}").txt"; done
  ```

## Things to know

- **Scanned with no text layer** (read the PDF pages as images): the 715
  owner's guides, quick reference guide, the 715/64-100 tech data sheets,
  the hardware installation guide, the sales guide and `WAX_ERS_V1.0_Redacted.pdf`.
- **`PCXL_ers.pdf` (PA-7100LC ERS) is in reverse page order** -- printed page N
  is PDF page 100-N.
- `Lasi_ers` text garbles every bit-field diagram; cite the PDF pages.
- The 715 service handbook's "715/64-100 block diagram" (Fig 6-3) is the 712's.
- `docs/review/01`..`05` grade every document for relevance to the 715/64-100.
