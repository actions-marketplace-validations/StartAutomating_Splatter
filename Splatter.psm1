. $psScriptRoot\Find-Splat.ps1
. $psScriptRoot\Get-Splat.ps1
. $psScriptRoot\Use-Splat.ps1

. $psScriptRoot\Initialize-Splatter.ps1

# ?@ Get the splat for a given command.
Set-Alias -Name '?@' -Value Get-Splat
Set-Alias -Name 'gSplat' -Value Get-Splat
Set-Alias -Name '??@' -Value Find-Splat
Set-Alias -Name 'fSplat' -Value Find-Splat
Set-Alias -Name '.@' -Value Use-Splat 
Set-Alias -Name '*@' -Value Use-Splat
Set-Alias -Name 'uSplat' -Value Use-Splat


${?@} = $GSplat = $GetSplat = ${function:Get-Splat}
${??@} = $FSplat = $FindSplat = ${function:Find-Splat}
${.@} = $USplat = $UseSplat = ${function:Use-Splat}

Export-ModuleMember -Alias * -Function * -Variable *