# $MawkId: reg4.awk,v 1.4 2009/07/12 22:23:58 tom Exp $
{
	if ($0 ~/^[-+()0-9.,$%/'"]*$/)
        {
		print ("reg4.1<<:",$0,">>")
	}
	if ($0 ~/^[]+()0-9.,$%/'"-]*$/)
        {
		print ("reg4.2<<:",$0,">>")
	}
	if ($0 ~/^[^]+()0-9.,$%/'"-]*$/)
        {
		print ("reg4.3<<:",$0,">>")
	}
}
