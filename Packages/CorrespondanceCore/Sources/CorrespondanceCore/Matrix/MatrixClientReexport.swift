// Le client REST vit dans sa propre cible, sans rien d'Apple : c'est ce qui
// permet à l'agent de tourner sur le NUC. Core le réexporte pour que l'app,
// l'iPhone et les tests continuent d'écrire `import CorrespondanceCore`.
@_exported import CorrespondanceMatrixClient
