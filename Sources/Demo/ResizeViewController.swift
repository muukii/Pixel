//
//  ResizeViewController.swift
//  Demo
//
//  Created by Hiroshi Kimura on 2018/10/24.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit

@testable import PixelEngine

final class ResizeViewController : UIViewController {
  
  override func viewDidLoad() {
    super.viewDidLoad()
  }
  
  @IBAction private func didTapResizeButton() {
    
    let uiImage = UIImage(named: "nasa.jpg")!
    
    let image = CIImage(image: uiImage)!
    
//    let r = ImageTool.makeNewResizedCIImage(to: CGSize(width: 1000, height: 1000), from: image)
    
//    print(r.debugDescription)
  }
  
  @IBAction private func didTapCGResizeButton() {
    
    let uiImage = UIImage(named: "nasa.jpg")!
    
    let image = CIImage(image: uiImage)!
    
    UIGraphicsBeginImageContextWithOptions(CGSize(width: 1000, height: 1000), false, 0)
    
    UIGraphicsGetCurrentContext()!.draw(image.cgImage!, in: .init(origin: .zero, size: CGSize(width: 1000, height: 1000)))
    
    let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    
    print(scaledImage.debugDescription)
  }
}
