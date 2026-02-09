@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Pester shares variables across BeforeAll/BeforeEach/It blocks
        # which PSScriptAnalyzer cannot track across script block boundaries.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
